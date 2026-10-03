"""争议证据临时保全。

交接复核期间，对一组仍生效的正式证据建立临时保全，避免其在复核完成前被撤回：

- 申请（`POST /preservations`）携带当前正式修订号、一组**不重复且均生效**的
  证据编号与事由；成功返回保全记录编号与**仅在创建时显示**的解除凭据
  （库中只存凭据的 sha256 摘要，任何查询接口都不返回凭据或摘要）。
- 查询（`GET /preservations`、`GET /preservations/{id}`）可见保全状态与每条
  证据的在保来源；解除（`POST /preservations/{id}/release`）凭对应凭据进行，
  错误凭据 / 保全不存在或已解除 / 过期修订均明确拒绝。
- 同一证据可被多份保全覆盖，须**全部**解除后才可撤回：普通批次、野外包勘误与
  推演并入凡将受保全证据撤回到正式库均整笔拒绝（409 `EVIDENCE_PRESERVED`，
  附命中的证据与保全记录），正式修订、台账与推演状态不变；推演内试验撤回
  不触碰正式库，仍可进行。
- 保全建立 / 解除与正式写入共用同一正式修订计数器行锁，并发下按一致的先后
  次序裁决；保全操作本身不递增正式修订号、不改变既有快照与台账。
"""
from __future__ import annotations

import hashlib
import secrets
from typing import Any, Dict, List, Optional

from .db import db_conn
from .errors import ApiError
from .models import PreservationIn, PreservationReleaseIn


def _credential_hash(credential: str) -> str:
    """解除凭据只存 sha256 摘要：库中不留明文，查询接口不下发。"""
    return hashlib.sha256(credential.encode("utf-8")).hexdigest()


# ------------------------------------------------------------------ 撤回拦截（正式批次 / 野外勘误 / 推演并入复用）
def preserved_hits(cur, evidence_ids: List[str]) -> List[Dict[str, Any]]:
    """仍被生效保全覆盖的证据及其在保来源（按证据编号、保全编号排序）。"""
    unique_ids = sorted(set(evidence_ids))
    if not unique_ids:
        return []
    cur.execute(
        "SELECT i.evidence_id, p.id, p.reason, p.created_revision, p.created_at "
        "FROM evidence_preservation_items i "
        "JOIN evidence_preservations p ON p.id = i.preservation_id "
        "WHERE p.status = 'active' AND i.evidence_id = ANY(%s) "
        "ORDER BY i.evidence_id, p.id",
        (unique_ids,),
    )
    hits: Dict[str, Dict[str, Any]] = {}
    for evidence_id, pid, reason, created_revision, created_at in cur.fetchall():
        hit = hits.setdefault(evidence_id, {"evidence_id": evidence_id, "preservations": []})
        hit["preservations"].append(
            {
                "id": pid,
                "reason": reason,
                "created_revision": created_revision,
                "created_at": created_at.isoformat(),
            }
        )
    return [hits[eid] for eid in sorted(hits)]


def raise_if_preserved(cur, evidence_ids: List[str], extra: Optional[Dict[str, Any]] = None) -> None:
    """任一证据仍被生效保全覆盖则整笔拒绝（调用方事务回滚，原状态不变）。"""
    hits = preserved_hits(cur, evidence_ids)
    if hits:
        raise ApiError(
            409,
            "EVIDENCE_PRESERVED",
            "证据仍处于保全状态，须解除覆盖它的全部保全后才可撤回，整笔拒绝，原状态不变",
            {**(extra or {}), "preserved_evidence": hits},
        )


# ------------------------------------------------------------------ 建立
def create_preservation(body: PreservationIn) -> Dict[str, Any]:
    """建立临时保全：不递增正式修订号；解除凭据仅在本响应中出现一次。"""
    evidence_ids = list(body.evidence_ids)
    if not evidence_ids:
        raise ApiError(400, "EMPTY_EVIDENCE", "保全证据集合为空", {})
    seen: set = set()
    duplicates: List[str] = []
    for eid in evidence_ids:
        if eid in seen and eid not in duplicates:
            duplicates.append(eid)
        seen.add(eid)
    if duplicates:
        raise ApiError(
            400,
            "DUPLICATE_EVIDENCE",
            f"保全申请内证据编号重复: {', '.join(duplicates)}",
            {"duplicate_evidence_ids": duplicates},
        )
    unique_ids = sorted(seen)

    with db_conn() as conn:
        with conn.cursor() as cur:
            # 与正式写入共用同一计数器行锁：建立 / 解除 / 正式写入按一致的先后次序裁决
            cur.execute("SELECT revision FROM revision_counter WHERE id = TRUE FOR UPDATE")
            current = cur.fetchone()[0]
            if body.expected_revision != current:
                raise ApiError(
                    409,
                    "STALE_REVISION",
                    f"修订号过期：请求携带 {body.expected_revision}，当前为 {current}",
                    {"current_revision": current},
                )
            cur.execute(
                "SELECT evidence_id, status FROM assertions WHERE evidence_id = ANY(%s)",
                (unique_ids,),
            )
            status_by_id = {r[0]: r[1] for r in cur.fetchall()}
            not_found = [e for e in unique_ids if e not in status_by_id]
            not_active = [e for e in unique_ids if status_by_id.get(e) not in (None, "active")]
            if not_found or not_active:
                raise ApiError(
                    400,
                    "INVALID_PRESERVATION_EVIDENCE",
                    "保全证据须全部存在且处于生效状态",
                    {"not_found": not_found, "not_active": not_active},
                )
            credential = secrets.token_urlsafe(32)
            cur.execute(
                "INSERT INTO evidence_preservations (reason, credential_hash, created_revision) "
                "VALUES (%s, %s, %s) RETURNING id, created_at",
                (body.reason, _credential_hash(credential), current),
            )
            pid, created_at = cur.fetchone()
            cur.executemany(
                "INSERT INTO evidence_preservation_items (preservation_id, evidence_id) VALUES (%s, %s)",
                [(pid, eid) for eid in unique_ids],
            )
            return {
                "id": pid,
                "status": "active",
                "reason": body.reason,
                "evidence_ids": unique_ids,
                "created_revision": current,
                "created_at": created_at.isoformat(),
                # 解除凭据仅在创建响应中显示一次；库中只存摘要，查询接口不再返回
                "release_credential": credential,
            }


# ------------------------------------------------------------------ 查询
_SELECT = (
    "SELECT id, reason, status, created_revision, created_at, released_revision, released_at "
    "FROM evidence_preservations"
)


def _items_by_preservation(cur, ids: List[int]) -> Dict[int, List[str]]:
    if not ids:
        return {}
    cur.execute(
        "SELECT preservation_id, evidence_id FROM evidence_preservation_items "
        "WHERE preservation_id = ANY(%s) ORDER BY preservation_id, evidence_id",
        (ids,),
    )
    items: Dict[int, List[str]] = {}
    for pid, eid in cur.fetchall():
        items.setdefault(pid, []).append(eid)
    return items


def _payload(row, evidence_ids: List[str]) -> Dict[str, Any]:
    """保全记录视图：永不含解除凭据或其摘要。"""
    pid, reason, status, created_revision, created_at, released_revision, released_at = row
    return {
        "id": pid,
        "status": status,
        "reason": reason,
        "evidence_ids": evidence_ids,
        "created_revision": created_revision,
        "created_at": created_at.isoformat(),
        "released_revision": released_revision,
        "released_at": released_at.isoformat() if released_at else None,
    }


def list_preservations(
    status: Optional[str] = None, evidence_id: Optional[str] = None
) -> List[Dict[str, Any]]:
    """保全台账列表：可按状态过滤；给 evidence_id 时列出该证据的全部在保来源。"""
    with db_conn() as conn:
        with conn.cursor() as cur:
            sql = _SELECT
            conditions: List[str] = []
            params: List[Any] = []
            if status is not None:
                conditions.append("status = %s")
                params.append(status)
            if evidence_id is not None:
                conditions.append(
                    "id IN (SELECT preservation_id FROM evidence_preservation_items WHERE evidence_id = %s)"
                )
                params.append(evidence_id)
            if conditions:
                sql += " WHERE " + " AND ".join(conditions)
            sql += " ORDER BY id"
            cur.execute(sql, params)
            rows = cur.fetchall()
            items = _items_by_preservation(cur, [r[0] for r in rows])
            return [_payload(r, items.get(r[0], [])) for r in rows]


def get_preservation(preservation_id: int) -> Dict[str, Any]:
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(_SELECT + " WHERE id = %s", (preservation_id,))
            row = cur.fetchone()
            if row is None:
                raise ApiError(
                    404,
                    "PRESERVATION_NOT_FOUND",
                    f"保全记录不存在: {preservation_id}",
                    {"preservation_id": preservation_id},
                )
            items = _items_by_preservation(cur, [preservation_id])
            return _payload(row, items.get(preservation_id, []))


# ------------------------------------------------------------------ 解除
def release_preservation(preservation_id: int, body: PreservationReleaseIn) -> Dict[str, Any]:
    """凭创建时下发的解除凭据解除指定保全；不递增正式修订号。"""
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, reason, status, credential_hash, created_revision, created_at, "
                "released_revision, released_at "
                "FROM evidence_preservations WHERE id = %s FOR UPDATE",
                (preservation_id,),
            )
            row = cur.fetchone()
            if row is None:
                raise ApiError(
                    404,
                    "PRESERVATION_NOT_FOUND",
                    f"保全记录不存在: {preservation_id}",
                    {"preservation_id": preservation_id},
                )
            _, reason, status, stored_hash, _, _, released_revision, released_at = row
            if status != "active":
                raise ApiError(
                    409,
                    "PRESERVATION_ALREADY_RELEASED",
                    f"保全 {preservation_id} 已解除，不可重复解除",
                    {
                        "preservation_id": preservation_id,
                        "released_revision": released_revision,
                        "released_at": released_at.isoformat() if released_at else None,
                    },
                )
            # 与正式写入共用同一计数器行锁：解除 / 建立 / 正式写入按一致的先后次序裁决
            cur.execute("SELECT revision FROM revision_counter WHERE id = TRUE FOR UPDATE")
            current = cur.fetchone()[0]
            if body.expected_revision != current:
                raise ApiError(
                    409,
                    "STALE_REVISION",
                    f"修订号过期：请求携带 {body.expected_revision}，当前为 {current}",
                    {"current_revision": current},
                )
            if not secrets.compare_digest(stored_hash, _credential_hash(body.credential)):
                raise ApiError(
                    403,
                    "PRESERVATION_CREDENTIAL_MISMATCH",
                    f"解除凭据错误，保全 {preservation_id} 维持生效",
                    {"preservation_id": preservation_id},
                )
            cur.execute(
                "UPDATE evidence_preservations "
                "SET status = 'released', released_revision = %s, released_at = now() "
                "WHERE id = %s",
                (current, preservation_id),
            )
            cur.execute(_SELECT + " WHERE id = %s", (preservation_id,))
            updated = cur.fetchone()
            items = _items_by_preservation(cur, [preservation_id])
            return _payload(updated, items.get(preservation_id, []))
