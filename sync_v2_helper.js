const fs = require('fs');
const path = require('path');
const zproto = require('./zproto_lib.js');

// Legacy location used by the original developers (an extracted Zalo PC `app.asar`).
const LEGACY_WASM_PATH = path.resolve(__dirname, '../asar_extracted/pc-dist/libs/libzproto_wasm_bg.ecc0555ba9d0f8867a4699ce943ec745.wasm');

// Zalo PC installs that may hold `libzproto_wasm_bg.*.wasm` inside `app.asar`.
// The wasm is read from the user's own install at runtime and is never redistributed.
const DEFAULT_ASAR_PATHS = [
    '/Applications/Zalo.app/Contents/Resources/app.asar',
    path.join(process.env.HOME || '', 'Applications/Zalo.app/Contents/Resources/app.asar'),
    path.join(process.env.LOCALAPPDATA || '', 'Programs/Zalo/resources/app.asar'),
];

// Read one file out of an Electron asar archive without extracting it.
// Layout: u32 4 | u32 headerPickleSize | u32 | u32 jsonLen | json | file data...
function readZprotoWasmFromAsar(asarPath) {
    const fd = fs.openSync(asarPath, 'r');
    try {
        const head = Buffer.alloc(16);
        fs.readSync(fd, head, 0, 16, 0);
        const headerSize = head.readUInt32LE(4);
        const jsonLen = head.readUInt32LE(12);
        const jsonBuf = Buffer.alloc(jsonLen);
        fs.readSync(fd, jsonBuf, 0, jsonLen, 16);
        const header = JSON.parse(jsonBuf.toString('utf8'));
        const libs = header.files && header.files['pc-dist'] && header.files['pc-dist'].files
            && header.files['pc-dist'].files.libs && header.files['pc-dist'].files.libs.files;
        if (!libs) return null;
        const name = Object.keys(libs).find(n => /^libzproto_wasm_bg\..*\.wasm$/.test(n));
        if (!name || libs[name].unpacked) return null;
        const entry = libs[name];
        const data = Buffer.alloc(entry.size);
        fs.readSync(fd, data, 0, entry.size, 8 + headerSize + Number(entry.offset));
        return data;
    } finally {
        fs.closeSync(fd);
    }
}

function loadWasmBytes() {
    const explicit = process.env.ZPROTO_WASM_PATH;
    if (explicit) return fs.readFileSync(explicit);
    if (fs.existsSync(LEGACY_WASM_PATH)) return fs.readFileSync(LEGACY_WASM_PATH);
    const asars = process.env.ZALO_ASAR_PATH ? [process.env.ZALO_ASAR_PATH] : DEFAULT_ASAR_PATHS;
    for (const asar of asars) {
        if (asar && fs.existsSync(asar)) {
            const bytes = readZprotoWasmFromAsar(asar);
            if (bytes) return bytes;
        }
    }
    throw new Error('libzproto_wasm not found: install Zalo PC or set ZPROTO_WASM_PATH');
}

// Each sync request keeps its keys and session in its own folder (SYNC_V2_DIR), so parallel or
// successive requests never overwrite each other's key material. Defaults to the working directory.
const WORK_DIR = process.env.SYNC_V2_DIR || '.';
const inWork = name => path.join(WORK_DIR, name);

let wasmReady = false;

async function initWasm() {
    if (!wasmReady) {
        await zproto.b(loadWasmBytes());
        wasmReady = true;
    }
}

async function generateV2Keys() {
    await initWasm();
    const ik = zproto.e();
    const ek = zproto.e();
    const res = {
        ik_pub: Buffer.from(ik.publicKey).toString('base64'),
        ik_priv: Buffer.from(ik.privateKey).toString('hex'),
        ek_pub: Buffer.from(ek.publicKey).toString('base64'),
        ek_priv: Buffer.from(ek.privateKey).toString('hex')
    };
    ik.free();
    ek.free();
    fs.writeFileSync(inWork('sync_v2_keys.json'), JSON.stringify(res, null, 2), { mode: 0o600 });
    return res;
}

async function decryptMeta(metaFilePath) {
    await initWasm();
    if (!fs.existsSync(inWork('sync_v2_keys.json'))) {
        throw new Error('sync_v2_keys.json not found');
    }
    const keys = JSON.parse(fs.readFileSync(inWork('sync_v2_keys.json'), 'utf8'));
    let metaBytes = fs.readFileSync(metaFilePath);
    
    // Strip 4-byte uint32 LE length header if present
    if (metaBytes.length >= 4) {
        const len = metaBytes.readUInt32LE(0);
        if (len === metaBytes.length - 4) {
            metaBytes = metaBytes.slice(4);
        }
    }
    
    const ik_pub = Buffer.from(keys.ik_pub, 'base64');
    const ik_priv = Buffer.from(keys.ik_priv, 'hex');
    const ek_priv = Buffer.from(keys.ek_priv, 'hex');

    const res = zproto.j(metaBytes, ik_pub, ik_priv, ek_priv, null);
    const sessionRecord = Buffer.from(res.sessionRecord);
    const plaintext = Buffer.from(res.plaintext);
    res.free();

    fs.writeFileSync(inWork('sync_v2_session.bin'), sessionRecord, { mode: 0o600 });
    return {
        sessionRecordHex: sessionRecord.toString('hex'),
        plainLen: plaintext.length
    };
}

async function decryptMessage(msgFilePath) {
    await initWasm();
    if (!fs.existsSync(inWork('sync_v2_session.bin'))) {
        throw new Error('sync_v2_session.bin not found');
    }
    const sessionRecord = fs.readFileSync(inWork('sync_v2_session.bin'));
    let msgBytes = fs.readFileSync(msgFilePath);

    // Strip 4-byte uint32 LE length header if present
    if (msgBytes.length >= 4) {
        const len = msgBytes.readUInt32LE(0);
        if (len === msgBytes.length - 4) {
            msgBytes = msgBytes.slice(4);
        }
    }

    const res = zproto.i(msgBytes, sessionRecord);
    const plaintext = Buffer.from(res.plaintext);
    res.free();

    fs.writeFileSync(inWork('sync_v2_message.bin'), plaintext);
    return {
        plainLen: plaintext.length
    };
}

// A downloaded batch is a run of records, each `u32 LE length | ciphertext` (Zalo PC reads it
// record by record). The first record of a session carries the metadata that establishes the
// session; later records are messages decrypted with that session. Output is a run of
// `u8 kind (1 = meta, 2 = message) | u32 LE length | plaintext` records.
function splitRecords(bytes) {
    const records = [];
    let offset = 0;
    while (offset + 4 <= bytes.length) {
        const len = bytes.readUInt32LE(offset);
        if (len === 0 || offset + 4 + len > bytes.length) break;
        records.push(bytes.slice(offset + 4, offset + 4 + len));
        offset += 4 + len;
    }
    // Not a record stream: treat the whole file as one ciphertext.
    return offset === bytes.length && records.length ? records : [bytes];
}

async function decryptBatch(batchPath, outPath) {
    await initWasm();
    const keys = JSON.parse(fs.readFileSync(inWork('sync_v2_keys.json'), 'utf8'));
    const ikPub = Buffer.from(keys.ik_pub, 'base64');
    const ikPriv = Buffer.from(keys.ik_priv, 'hex');
    const ekPriv = Buffer.from(keys.ek_priv, 'hex');
    const sessionPath = inWork('sync_v2_session.bin');
    const out = [];
    let meta = 0, messages = 0, failed = 0;
    const push = (kind, plain) => {
        const head = Buffer.alloc(5);
        head.writeUInt8(kind, 0);
        head.writeUInt32LE(plain.length, 1);
        out.push(head, plain);
    };
    const tryMeta = record => {
        const res = zproto.j(record, ikPub, ikPriv, ekPriv, null);
        const session = Buffer.from(res.sessionRecord);
        const plain = Buffer.from(res.plaintext);
        res.free();
        fs.writeFileSync(sessionPath, session, { mode: 0o600 });
        push(1, plain); meta++;
    };
    const tryMessage = record => {
        const res = zproto.i(record, fs.readFileSync(sessionPath));
        const plain = Buffer.from(res.plaintext);
        res.free();
        push(2, plain); messages++;
    };
    for (const record of splitRecords(fs.readFileSync(batchPath))) {
        const order = fs.existsSync(sessionPath) ? [tryMessage, tryMeta] : [tryMeta, tryMessage];
        let done = false;
        for (const attempt of order) {
            try { attempt(record); done = true; break; } catch (_) { /* try the other kind */ }
        }
        if (!done) failed++;
    }
    fs.writeFileSync(outPath, Buffer.concat(out));
    return { meta, messages, failed };
}

const cmd = process.argv[2];
if (cmd === 'gen-keys') {
    generateV2Keys().then(keys => {
        console.log(JSON.stringify(keys));
        process.exit(0);
    }).catch(e => {
        console.error(e);
        process.exit(1);
    });
} else if (cmd === 'decrypt-meta') {
    const metaPath = process.argv[3];
    decryptMeta(metaPath).then(res => {
        console.log(JSON.stringify(res));
        process.exit(0);
    }).catch(e => {
        console.error(e);
        process.exit(1);
    });
} else if (cmd === 'decrypt-batch') {
    decryptBatch(process.argv[3], process.argv[4]).then(res => {
        console.log(JSON.stringify(res));
        process.exit(0);
    }).catch(e => {
        console.error(String(e && e.message || e));
        process.exit(1);
    });
} else if (cmd === 'decrypt-message') {
    const msgPath = process.argv[3];
    decryptMessage(msgPath).then(res => {
        console.log(JSON.stringify(res));
        process.exit(0);
    }).catch(e => {
        console.error(e);
        process.exit(1);
    });
}

module.exports = { generateV2Keys, decryptMeta, decryptMessage, decryptBatch, splitRecords, initWasm, zproto };
