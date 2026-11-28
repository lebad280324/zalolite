//! Protocol adapters reused from the existing feature worktree.
//!
//! Alias evidence: re-notes/36_mentions_alias.md (2026-11-05/06). Member and
//! pinned-topic shapes match the existing feature checkout's chat helpers.

use crate::{
    chat,
    session::{Session, SessionError},
};
use anyhow::{bail, Result};
use serde_json::{json, Value};

fn checked(response: &Value) -> Result<()> {
    match response.get("error_code").and_then(Value::as_i64) {
        Some(0) => Ok(()),
        Some(code) => Err(SessionError::new(code, "Zalo rejected the request").into()),
        None => bail!("Zalo response has no result code"),
    }
}

pub(super) fn safe_url(value: Option<&str>) -> Option<String> {
    value
        .filter(|value| {
            reqwest::Url::parse(value).is_ok_and(|url| {
                matches!(url.scheme(), "https" | "http")
                    && url.host_str().is_some()
                    && url.username().is_empty()
                    && url.password().is_none()
            })
        })
        .map(str::to_owned)
}

pub(super) async fn update_alias(session: &Session, uid: &str, alias: &str) -> Result<()> {
    let (path, body) = if alias.trim().is_empty() {
        ("/api/alias/remove", json!({"friendId": uid}))
    } else {
        (
            "/api/alias/update",
            json!({"friendId":uid,"alias":alias.trim(),"imei":session.imei}),
        )
    };
    let encoded = session.encoded_params(&body)?;
    let response = session
        .get_endpoint(
            "alias",
            &format!("{path}?{}&params={encoded}", session.common_params()),
        )
        .await?;
    checked(
        &session
            .maybe_decrypt(response, session.session_key_bytes())
            .await,
    )
}

/// Nicknames this account gave its contacts (`getAlias`, cmd 12200, in the installed Zalo PC bundle:
/// `GET {alias}/api/alias/list?{common}&params=enc({page,count,imei})`). See re-notes/63.
pub(super) async fn alias_list(session: &Session) -> Result<Vec<Value>> {
    const PAGE: usize = 100;
    let mut out = Vec::new();
    for page in 1..=50 {
        let encoded = session.encoded_params(&json!({"page": page, "count": PAGE, "imei": session.imei}))?;
        let response = session
            .get_endpoint(
                "alias",
                &format!("/api/alias/list?{}&params={encoded}", session.common_params()),
            )
            .await?;
        let response = session
            .maybe_decrypt(response, session.session_key_bytes())
            .await;
        checked(&response)?;
        let items = parse_aliases(&response);
        let count = items.len();
        out.extend(items);
        if count < PAGE {
            break;
        }
    }
    Ok(out)
}

/// `{user_id, alias}` rows from an alias list response; tolerant of the list's wrapper key.
pub(super) fn parse_aliases(response: &Value) -> Vec<Value> {
    let data = response.get("data").unwrap_or(response);
    let list = data
        .get("items")
        .or_else(|| data.get("aliases"))
        .or_else(|| data.get("list"))
        .and_then(Value::as_array)
        .or_else(|| data.as_array());
    list.into_iter()
        .flatten()
        .filter_map(|item| {
            let user_id = pick(item, &["userId", "uid", "friendId", "id"]);
            let alias = pick(item, &["alias", "aliasName", "name"]);
            (!user_id.is_empty() && !alias.is_empty() && user_id.len() <= 32)
                .then(|| json!({"user_id": user_id, "alias": alias.chars().take(256).collect::<String>()}))
        })
        .collect()
}

pub(super) fn parse_pinned(response: &Value) -> Vec<Value> {
    let data = response.get("data").unwrap_or(response);
    data.get("topics")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(500)
        .filter_map(|topic| {
            let params = match topic.get("params") {
                Some(Value::String(text)) => serde_json::from_str(text).unwrap_or(Value::Null),
                Some(value) => value.clone(),
                None => Value::Null,
            };
            let text = pick(
                &params,
                &["title", "content", "msg", "message", "description"],
            );
            let text = if text.is_empty() {
                pick(topic, &["title", "content"])
            } else {
                text
            };
            if text.is_empty() {
                return None;
            }
            Some(json!({"topic_id":pick(topic,&["id","topicId","topic_id"]),
          "message_id":pick(&params,&["global_msg_id","globalMsgId","msgId","msg_id"]),
          "text":text.chars().take(20_000).collect::<String>(),
          "sender_name":pick(&params,&["senderName","sender_name","dName","fromName"])}))
        })
        .collect()
}

pub(super) async fn pinned_topics(session: &Session, thread_id: &str) -> Result<Vec<Value>> {
    let id = thread_id
        .trim_start_matches("group_")
        .trim_start_matches('g')
        .trim_start_matches('G');
    let params =
        session.encoded_params(&json!({"groupId":id,"boardVersion":0,"imei":session.imei}))?;
    let response = session
        .get_endpoint(
            "group_board",
            &format!(
                "/api/board/pin/list?{}&params={params}",
                session.common_params()
            ),
        )
        .await?;
    let response = session
        .maybe_decrypt(response, session.session_key_bytes())
        .await;
    checked(&response)?;
    Ok(parse_pinned(&response))
}

/// Friend requests sent to this account, as Zalo PC's `getListFriendRequest` reads them from
/// `/api/friend/recommendsv2/list`: items of `recommItems` whose `dataInfo.recommType` is 2,
/// newest first (re-notes/81). Other items are friend suggestions.
pub(super) fn received_friend_requests(data: &Value) -> Option<Vec<Value>> {
    let items = data.get("recommItems")?.as_array()?;
    let mut rows: Vec<(i64, Value)> = items
        .iter()
        .filter_map(|item| item.get("dataInfo"))
        .filter(|info| info.get("recommType").and_then(Value::as_i64) == Some(2))
        .filter_map(|info| {
            let id = pick(info, &["userId", "uid"]);
            let name = pick(info, &["displayName", "zaloName"]);
            if id.is_empty() {
                return None;
            }
            let name = if name.is_empty() { "Người dùng Zalo".to_owned() } else { name };
            let time = info.get("recommTime").and_then(Value::as_i64).unwrap_or(-1);
            let message = info
                .get("recommInfo")
                .map(|recomm| pick(recomm, &["message"]))
                .unwrap_or_default();
            let row = json!({"id":id,"user_id":id,"name":name,"display_name":name,
                "avatar":safe_url(info.get("avatar").and_then(Value::as_str)),
                "message":message,"time":if time > 0 { json!(time) } else { Value::Null },"is_group":false});
            Some((time, row))
        })
        .collect();
    rows.sort_by_key(|row| std::cmp::Reverse(row.0));
    Some(rows.into_iter().map(|(_, row)| row).collect())
}

pub(super) fn pick(value: &Value, keys: &[&str]) -> String {
    keys.iter()
        .find_map(|key| match value.get(*key) {
            Some(Value::String(text)) if !text.trim().is_empty() => Some(text.trim().to_owned()),
            Some(Value::Number(number)) => Some(number.to_string()),
            _ => None,
        })
        .unwrap_or_default()
}

pub(super) async fn members(session: &Session, thread_id: &str) -> Result<Vec<Value>> {
    let id = thread_id
        .trim_start_matches("group_")
        .trim_start_matches('g')
        .trim_start_matches('G');
    let (info, _) = chat::fetch_group_profiles(session, &[id.to_owned()]).await?;
    let Some(group) = info.get(id).or_else(|| info.get(thread_id)) else {
        bail!("Group metadata missing");
    };
    let mut ids = Vec::new();
    for item in group
        .get("memVerList")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(5000)
    {
        if let Some(id) = item
            .as_str()
            .and_then(|value| value.split('_').next())
            .filter(|value| !value.is_empty())
        {
            if !ids.iter().any(|item| item == id) {
                ids.push(id.to_owned());
            }
        }
    }
    let creator = pick(group, &["creatorId"]);
    let admins: Vec<String> = group
        .get("adminIds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .or_else(|| value.as_u64().map(|id| id.to_string()))
        })
        .collect();
    let mut profiles = serde_json::Map::new();
    for chunk in ids.chunks(50) {
        profiles.extend(chat::get_mini_profiles(session, chunk).await?);
    }
    let mut rows: Vec<Value> = ids
        .into_iter()
        .map(|id| {
            let profile = profiles.get(&id).unwrap_or(&Value::Null);
            let name = pick(
                profile,
                &["displayName", "zaloName", "name", "display_name"],
            );
            json!({"role":if id==creator {2} else if admins.contains(&id) {1} else {0},
          "id":id,"name":if name.is_empty(){"Thành viên".into()}else{name},
          "avatar":safe_url(Some(&pick(profile,&["avatar","avt","profile_avatar"])))})
        })
        .collect();
    rows.sort_by(|a, b| {
        b["role"]
            .as_i64()
            .cmp(&a["role"].as_i64())
            .then_with(|| a["name"].as_str().cmp(&b["name"].as_str()))
    });
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn received_friend_requests_keep_only_requests_newest_first() {
        let data = json!({"recommItems":[
            {"recommItemType":1,"dataInfo":{"userId":"1","displayName":"Gợi ý","recommType":1,"recommTime":5}},
            {"recommItemType":1,"dataInfo":{"userId":"2","displayName":"Cũ","recommType":2,"recommTime":10,
                "recommInfo":{"message":"Xin chào","source":1},"avatar":"https://s120.avatar.talk.zdn.vn/a.jpg"}},
            {"recommItemType":1,"dataInfo":{"userId":"3","zaloName":"Mới","recommType":2,"recommTime":20}}
        ]});
        let rows = received_friend_requests(&data).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["id"], "3");
        assert_eq!(rows[0]["name"], "Mới");
        assert_eq!(rows[1]["message"], "Xin chào");
        assert_eq!(rows[1]["time"], 10);
        assert!(received_friend_requests(&json!({"recommItems":[]})).unwrap().is_empty());
        assert!(received_friend_requests(&json!({"other":1})).is_none());
    }
    #[test]
    fn pinned_metadata_excludes_unknown_and_secret_fields() {
        let output = parse_pinned(
            &json!({"data":{"topics":[{"id":"topic-1","params":"{\"msgId\":\"msg-1\",\"title\":\"Example\",\"zpw_sek\":\"never\"}"}]}}),
        );
        assert_eq!(output[0]["message_id"], "msg-1");
        assert!(!serde_json::to_string(&output).unwrap().contains("never"));
    }
    #[test]
    fn media_urls_reject_credentials_and_non_web_schemes() {
        assert!(safe_url(Some("file:///secret")).is_none());
        assert!(safe_url(Some("https://user:pass@example.com/")).is_none());
        assert!(safe_url(Some("https://example.com/image")).is_some());
    }
}

/// Build only observed request fields; optional tracking arrays remain absent when unused.
pub(super) fn create_group_params(
    session: &Session,
    name: &str,
    members: &[String],
    client_id: u64,
) -> Value {
    json!({"clientId":client_id,"gname":name,"gdesc":null,"members":members,
      "nameChanged":1,"createLink":1,"clientLang":"vi","imei":session.imei,"groupType":null})
}

pub(super) async fn get_json(
    session: &Session,
    service: &str,
    path: &str,
    params: &Value,
) -> Result<Value> {
    let encoded = session.encoded_params(params)?;
    let response = session
        .get_endpoint(
            service,
            &format!("{path}?{}&params={encoded}", session.common_params()),
        )
        .await?;
    let response = session
        .maybe_decrypt(response, session.session_key_bytes())
        .await;
    checked(&response)?;
    Ok(response.get("data").cloned().unwrap_or(Value::Null))
}

pub(super) async fn post_json(
    session: &Session,
    service: &str,
    path: &str,
    params: &Value,
) -> Result<Value> {
    let encoded = session.encoded_params(params)?;
    let response = session
        .post_endpoint_form(
            service,
            &format!("{path}?{}", session.common_params()),
            format!("params={encoded}"),
        )
        .await?;
    let response = session
        .maybe_decrypt(response, session.session_key_bytes())
        .await;
    checked(&response)?;
    Ok(response.get("data").cloned().unwrap_or(Value::Null))
}

/// User IDs in a block list. Besides profile objects, Zalo may answer with bare ID arrays or
/// objects keyed by user ID, which carry no names; those rows fall back to the ID.
pub(super) fn blocked_rows(data: &Value) -> Vec<Value> {
    let mut rows: std::collections::BTreeMap<String, Value> = profile_rows(data, false)
        .into_iter()
        .filter_map(|row| Some((row["id"].as_str()?.to_owned(), row)))
        .collect();
    let numeric = |text: &str| !text.is_empty() && text.len() <= 32 && text.bytes().all(|b| b.is_ascii_digit());
    let mut queue = std::collections::VecDeque::from([data]);
    let mut visited = 0;
    while let Some(value) = queue.pop_front() {
        visited += 1;
        if visited > 8000 || rows.len() >= 1000 {
            break;
        }
        let mut add = |id: String| {
            rows.entry(id.clone())
                .or_insert_with(|| json!({"id":id,"user_id":id,"name":"","display_name":"","avatar":null,"is_group":false}));
        };
        match value {
            Value::Array(items) => {
                for item in items.iter().take(1000) {
                    match item {
                        Value::String(id) if numeric(id) => add(id.clone()),
                        Value::Number(id) => add(id.to_string()),
                        other if other.is_object() || other.is_array() => queue.push_back(other),
                        _ => {}
                    }
                }
            }
            Value::Object(object) => {
                let id = pick(value, &["userId", "uid", "user_id", "fid"]);
                if numeric(&id) {
                    add(id);
                }
                for (key, child) in object {
                    // `{ "<uid>": {...} }` or `{ "<uid>": 1 }`.
                    if numeric(key) && !child.is_array() {
                        add(key.clone());
                    }
                    if child.is_object() || child.is_array() {
                        queue.push_back(child);
                    }
                }
            }
            _ => {}
        }
    }
    rows.into_values().collect()
}

pub(super) fn profile_rows(data: &Value, group: bool) -> Vec<Value> {
    let mut queue = std::collections::VecDeque::from([data]);
    let mut rows = std::collections::BTreeMap::new();
    let mut visited = 0;
    while let Some(value) = queue.pop_front() {
        visited += 1;
        if visited > 8000 || rows.len() >= 1000 {
            break;
        }
        if let Some(object) = value.as_object() {
            let id = pick(
                value,
                if group {
                    &["groupId", "grid", "grId", "group_id"]
                } else {
                    &["userId", "uid", "user_id", "fid"]
                },
            );
            let name = pick(
                value,
                if group {
                    &["name", "groupName", "gname"]
                } else {
                    &["displayName", "zaloName", "name", "dName"]
                },
            );
            if !id.is_empty() && !name.is_empty() {
                rows.insert(id.clone(),json!({"id":id,"user_id":id,"name":name,"display_name":name,
                  "avatar":safe_url(Some(&pick(value,&["avatar","avt","groupAvatar"]))),"is_group":group}));
            }
            for child in object.values() {
                if child.is_object() || child.is_array() {
                    queue.push_back(child);
                }
            }
        } else if let Some(array) = value.as_array() {
            queue.extend(array.iter().take(1000));
        }
    }
    rows.into_values().collect()
}

#[cfg(test)]
mod alias_tests {
    use super::*;

    #[test]
    fn block_list_accepts_bare_ids_and_keyed_objects() {
        let rows = blocked_rows(&json!({"data":["123","456"]}));
        assert_eq!(rows.len(), 2);
        let rows = blocked_rows(&json!({"blockedUids":{"789":1}}));
        assert_eq!(rows[0]["id"], "789");
        let rows = blocked_rows(&json!({"data":[{"userId":"42","displayName":"A"}]}));
        assert_eq!(rows[0]["name"], "A");
        assert!(blocked_rows(&json!({"total":0,"data":[]})).is_empty());
    }

    #[test]
    fn alias_rows_keep_only_people_with_a_nickname() {
        let response = json!({"error_code": 0, "data": {"items": [
            {"userId": "123", "alias": "Sếp Phương"},
            {"userId": 456, "alias": ""},
            {"alias": "no id"}
        ]}});
        assert_eq!(parse_aliases(&response), vec![json!({"user_id": "123", "alias": "Sếp Phương"})]);
        assert!(parse_aliases(&json!({"error_code": 0, "data": {}})).is_empty());
    }
}
