#!/usr/bin/env bash
# 考古地层关系核验服务 —— 争议证据临时保全
# （POST /preservations、GET /preservations、POST /preservations/{id}/release）端到端示例
#
# 争议中的正式证据在交接复核期间需要临时保全，避免被撤回：
#   - 申请携带当前正式修订号、一组不重复且均生效的证据编号与事由；
#     成功返回保全记录编号与**仅在创建时显示**的解除凭据（查询接口不泄露凭据）；
#   - 同一证据被多份保全覆盖时，须全部解除后才可撤回；
#   - 普通批次、野外包勘误与推演并入凡将受保全证据撤回到正式库均整笔拒绝
#     （409 EVIDENCE_PRESERVED，附命中证据与保全记录），正式修订、台账与推演状态不变；
#     推演内试验撤回仍可进行；
#   - 保全建立 / 解除不递增正式修订号、不改变既有快照。
#
# 前提：服务已启动（docker compose up --build），监听 http://localhost:8000
set -euo pipefail

BASE="${BASE_URL:-http://localhost:8000}"
pp() { python3 -m json.tool 2>/dev/null || cat; }
revision() { curl -s "$BASE/revision" | python3 -c 'import sys,json;print(json.load(sys.stdin)["revision"])'; }

echo "== 0. 登记本示例专用地层并建立正式视图 =="
for s in PS1 PS2 PS3 PS4; do
  curl -s -X POST "$BASE/strata" -H 'Content-Type: application/json' \
    -d "{\"stratum_id\": \"$s\", \"site\": \"保全演示区\"}" > /dev/null || true
done
# 可重复执行：仅当本示例证据尚未入库时提交种子批次
if ! curl -s "$BASE/assertions" | grep -q '"PSV-1"'; then
  curl -s -X POST "$BASE/batches" -H 'Content-Type: application/json' -d "{
    \"expected_revision\": $(revision),
    \"operations\": [
      {\"op\": \"assert\", \"evidence_id\": \"PSV-1\", \"stratum_a\": \"PS1\", \"stratum_b\": \"PS2\", \"relation\": \"same_period\"},
      {\"op\": \"assert\", \"evidence_id\": \"PSV-2\", \"stratum_a\": \"PS2\", \"stratum_b\": \"PS3\", \"relation\": \"earlier_than\"},
      {\"op\": \"assert\", \"evidence_id\": \"PSV-3\", \"stratum_a\": \"PS3\", \"stratum_b\": \"PS4\", \"relation\": \"earlier_than\"}
    ]}" | pp
fi
REV="$(revision)"
echo "（当前修订号 $REV：PSV-1 PS1~PS2 同一期，PSV-2 PS2<PS3，PSV-3 PS3<PS4）"

echo; echo "== 1. 建立保全：PSV-1 与 PSV-2 进入交接复核 =="
echo "   申请携带当前修订号 + 不重复且均生效的证据编号 + 事由；"
echo "   响应中的 release_credential 仅在创建时显示一次"
REV_BEFORE="$(revision)"
P1_RESP="$(curl -s -X POST "$BASE/preservations" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV_BEFORE,
  \"evidence_ids\": [\"PSV-1\", \"PSV-2\"],
  \"reason\": \"争议证据交接复核（第一复核组）\"}")"
echo "$P1_RESP" | pp
P1="$(echo "$P1_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
CRED1="$(echo "$P1_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["release_credential"])')"
echo "   保全编号 $P1；建立前后修订号不变：$REV_BEFORE -> $(revision)"

echo; echo "== 2. 查询：保全状态与每条证据的在保来源（响应不含凭据） =="
echo "-- 2a. 台账列表 --"
curl -s "$BASE/preservations" | pp
echo "-- 2b. 单条详情 --"
curl -s "$BASE/preservations/$P1" | pp
echo "-- 2c. 按证据过滤：PSV-1 的在保来源 --"
curl -s "$BASE/preservations?evidence_id=PSV-1" | pp
echo "-- 2d. 校验查询响应不泄露凭据字段 --"
curl -s "$BASE/preservations" | python3 -c '
import sys, json
rows = json.load(sys.stdin)
assert rows and all("release_credential" not in r and "credential_hash" not in r for r in rows)
print("查询响应不含解除凭据或摘要（不泄露成立）")'

echo; echo "== 3. 普通批次撤回受保全证据：整批拒绝（409 EVIDENCE_PRESERVED），附命中证据与保全记录 =="
curl -s -X POST "$BASE/batches" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $(revision),
  \"operations\": [{\"op\": \"retract\", \"evidence_id\": \"PSV-1\"}]}" | pp
echo "   修订号不变：$(revision)；PSV-1 仍生效："
curl -s "$BASE/assertions?status=active" | python3 -c '
import sys, json
assert any(a["evidence_id"] == "PSV-1" for a in json.load(sys.stdin))
print("   PSV-1 active（整批拒绝，原状态不变）")'

echo; echo "== 4. 多份保全覆盖同一证据：须全部解除后才可撤回 =="
P2_RESP="$(curl -s -X POST "$BASE/preservations" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $(revision),
  \"evidence_ids\": [\"PSV-1\"],
  \"reason\": \"争议证据交接复核（第二复核组）\"}")"
echo "$P2_RESP" | pp
P2="$(echo "$P2_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
CRED2="$(echo "$P2_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["release_credential"])')"
echo "   PSV-1 的在保来源现为两份（$P1 与 $P2）："
curl -s "$BASE/preservations?evidence_id=PSV-1&status=active" | python3 -c '
import sys, json
print("   active 保全编号:", [r["id"] for r in json.load(sys.stdin)])'

echo; echo "== 5. 解除的明确拒绝：错误凭据 / 过期修订 / 不存在的保全 =="
echo "-- 5a. 错误凭据：403 PRESERVATION_CREDENTIAL_MISMATCH --"
curl -s -X POST "$BASE/preservations/$P1/release" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"credential\": \"wrong-credential\"}" | pp
echo "-- 5b. 过期修订：409 STALE_REVISION --"
curl -s -X POST "$BASE/preservations/$P1/release" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": 999999, \"credential\": \"$CRED1\"}" | pp
echo "-- 5c. 保全不存在：404 PRESERVATION_NOT_FOUND --"
curl -s -X POST "$BASE/preservations/999999/release" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"credential\": \"x\"}" | pp

echo; echo "== 6. 凭正确凭据解除第一份保全；第二份仍覆盖 PSV-1，撤回仍被拒绝 =="
REV_BEFORE="$(revision)"
curl -s -X POST "$BASE/preservations/$P1/release" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $REV_BEFORE, \"credential\": \"$CRED1\"}" | pp
echo "   解除前后修订号不变：$REV_BEFORE -> $(revision)"
curl -s -X POST "$BASE/batches" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $(revision),
  \"operations\": [{\"op\": \"retract\", \"evidence_id\": \"PSV-1\"}]}" | pp

echo; echo "== 7. 全部解除后撤回成功；重复解除明确拒绝 =="
curl -s -X POST "$BASE/preservations/$P2/release" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"credential\": \"$CRED2\"}" | pp
REV_BEFORE="$(revision)"
curl -s -X POST "$BASE/batches" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $REV_BEFORE,
  \"operations\": [{\"op\": \"retract\", \"evidence_id\": \"PSV-1\"}]}" | pp
echo "   撤回成功，修订号 $REV_BEFORE -> $(revision)"
echo "-- 重复解除：409 PRESERVATION_ALREADY_RELEASED --"
curl -s -X POST "$BASE/preservations/$P2/release" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"credential\": \"$CRED2\"}" | pp

echo; echo "== 8. 申请的明确拒绝：空集合 / 重复编号 / 无效证据 / 过期修订 =="
echo "-- 8a. 空集合：400 EMPTY_EVIDENCE --"
curl -s -X POST "$BASE/preservations" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"evidence_ids\": [], \"reason\": \"x\"}" | pp
echo "-- 8b. 申请内重复：400 DUPLICATE_EVIDENCE --"
curl -s -X POST "$BASE/preservations" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"evidence_ids\": [\"PSV-2\", \"PSV-2\"], \"reason\": \"x\"}" | pp
echo "-- 8c. 证据不存在或已撤回：400 INVALID_PRESERVATION_EVIDENCE（details 区分 not_found / not_active） --"
curl -s -X POST "$BASE/preservations" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"evidence_ids\": [\"PSV-404\", \"PSV-1\"], \"reason\": \"x\"}" | pp
echo "-- 8d. 过期修订：409 STALE_REVISION --"
curl -s -X POST "$BASE/preservations" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": 999999, \"evidence_ids\": [\"PSV-2\"], \"reason\": \"x\"}" | pp

echo; echo "== 9. 野外包勘误：撤回受保全证据整笔拒绝，台账与修订不变 =="
if ! curl -s "$BASE/field-packages/PT-DEMO/PS-PKG-1" | grep -q '"evidence"'; then
  curl -s -X POST "$BASE/field-packages" -H 'Content-Type: application/json' -d "{
    \"site\": \"保全演示站\", \"terminal_id\": \"PT-DEMO\", \"package_no\": \"PS-PKG-1\",
    \"expected_revision\": $(revision),
    \"mappings\": [
      {\"short_code\": \"a\", \"stratum_id\": \"PSF-01\"},
      {\"short_code\": \"b\", \"stratum_id\": \"PSF-02\"}
    ],
    \"assertions\": [
      {\"seq\": 1, \"stratum_a\": \"a\", \"stratum_b\": \"b\", \"relation\": \"same_period\"}
    ]}" | pp
fi
FEV="$(curl -s "$BASE/field-packages/PT-DEMO/PS-PKG-1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["evidence"][0]["evidence_id"])')"
echo "   野外包证据编号 $FEV；对其建立保全："
P3_RESP="$(curl -s -X POST "$BASE/preservations" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $(revision),
  \"evidence_ids\": [\"$FEV\"],
  \"reason\": \"野外包证据争议复核\"}")"
echo "$P3_RESP" | pp
P3="$(echo "$P3_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
CRED3="$(echo "$P3_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["release_credential"])')"
echo "-- 9a. 勘误被拦截：409 EVIDENCE_PRESERVED（附包上下文与命中保全） --"
REV_BEFORE="$(revision)"
curl -s -X POST "$BASE/field-packages/corrections" -H 'Content-Type: application/json' -d "{
  \"terminal_id\": \"PT-DEMO\", \"original_package_no\": \"PS-PKG-1\", \"new_package_no\": \"PS-PKG-1F1\",
  \"expected_revision\": $(revision), \"site\": \"保全演示站\",
  \"mappings\": [
    {\"short_code\": \"a\", \"stratum_id\": \"PSF-01\"},
    {\"short_code\": \"b\", \"stratum_id\": \"PSF-02\"}
  ],
  \"assertions\": [
    {\"seq\": 1, \"stratum_a\": \"a\", \"stratum_b\": \"b\", \"relation\": \"earlier_than\"}
  ]}" | pp
echo "   修订号不变：$REV_BEFORE -> $(revision)；原包台账仍 active、勘误台账为空："
curl -s "$BASE/field-packages/PT-DEMO/PS-PKG-1" | python3 -c '
import sys, json
print("   原包 status =", json.load(sys.stdin)["status"])'
curl -s "$BASE/field-packages/corrections?terminal_id=PT-DEMO" | pp
echo "-- 9b. 解除保全后勘误通过 --"
curl -s -X POST "$BASE/preservations/$P3/release" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"credential\": \"$CRED3\"}" | pp
curl -s -X POST "$BASE/field-packages/corrections" -H 'Content-Type: application/json' -d "{
  \"terminal_id\": \"PT-DEMO\", \"original_package_no\": \"PS-PKG-1\", \"new_package_no\": \"PS-PKG-1F1\",
  \"expected_revision\": $(revision), \"site\": \"保全演示站\",
  \"mappings\": [
    {\"short_code\": \"a\", \"stratum_id\": \"PSF-01\"},
    {\"short_code\": \"b\", \"stratum_id\": \"PSF-02\"}
  ],
  \"assertions\": [
    {\"seq\": 1, \"stratum_a\": \"a\", \"stratum_b\": \"b\", \"relation\": \"earlier_than\"}
  ]}" | pp

echo; echo "== 10. 推演并入：推演内试验撤回仍可进行；并入撤回受保全证据整笔拒绝 =="
PROJ="$(curl -s -X POST "$BASE/projections" -H 'Content-Type: application/json' -d '{"label": "保全并入演示"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
echo "   推演 $PROJ 已创建；推演内撤回基线证据 PSV-2（试验撤回，不触碰正式库）："
curl -s -X POST "$BASE/projections/$PROJ/batches" -H 'Content-Type: application/json' -d '{
  "expected_revision": 0,
  "operations": [{"op": "retract", "evidence_id": "PSV-2"}]}' | pp
echo "   正式侧对 PSV-2 建立保全后并入："
P4_RESP="$(curl -s -X POST "$BASE/preservations" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $(revision),
  \"evidence_ids\": [\"PSV-2\"],
  \"reason\": \"并入前复核\"}")"
P4="$(echo "$P4_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
CRED4="$(echo "$P4_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["release_credential"])')"
echo "-- 10a. 并入被拦截：409 EVIDENCE_PRESERVED，推演保持 open --"
curl -s -X POST "$BASE/projections/$PROJ/merge" | pp
curl -s "$BASE/projections/$PROJ" | python3 -c '
import sys, json
print("   推演状态:", json.load(sys.stdin)["status"])'
echo "-- 10b. 解除保全后并入成功 --"
curl -s -X POST "$BASE/preservations/$P4/release" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"credential\": \"$CRED4\"}" | pp
curl -s -X POST "$BASE/projections/$PROJ/merge" | pp

echo; echo "== 11. 保全操作不改变既有快照：定版内容前后一致 =="
SNAP="$(curl -s -X POST "$BASE/snapshots" -H 'Content-Type: application/json' -d '{"label": "保全不变性对照"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])')"
curl -s "$BASE/snapshots/$SNAP" > /tmp/ps_snap_before.json
P5_RESP="$(curl -s -X POST "$BASE/preservations" -H 'Content-Type: application/json' -d "{
  \"expected_revision\": $(revision),
  \"evidence_ids\": [\"PSV-3\"],
  \"reason\": \"快照不变性验证\"}")"
P5="$(echo "$P5_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
CRED5="$(echo "$P5_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["release_credential"])')"
curl -s -X POST "$BASE/preservations/$P5/release" -H 'Content-Type: application/json' \
  -d "{\"expected_revision\": $(revision), \"credential\": \"$CRED5\"}" > /dev/null
curl -s "$BASE/snapshots/$SNAP" > /tmp/ps_snap_after.json
if diff -q /tmp/ps_snap_before.json /tmp/ps_snap_after.json > /dev/null; then
  echo "   定版 $SNAP 内容在保全建立 / 解除前后完全一致（既有快照不变）"
else
  echo "   定版内容发生变化（不应发生）"; diff /tmp/ps_snap_before.json /tmp/ps_snap_after.json; exit 1
fi

echo; echo "== 12. 台账留痕：已解除保全仍可查询（状态 released，不含凭据） =="
curl -s "$BASE/preservations?status=released" | pp

echo; echo "全部争议证据临时保全示例执行完毕（当前修订号 $(revision)）。"
