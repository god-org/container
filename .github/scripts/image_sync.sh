#!/bin/bash

set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "❌ 要求 Bash 版本 ≥ 4.0，当前版本：${BASH_VERSION}。" >&2
  exit 127
fi

LIST_FILE="${GITHUB_WORKSPACE:-.}/containers.list"
TARGET_REGISTRY="ghcr.io/${REPO_OWNER:-}"

function log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ✅：${*}。"
}

function error() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ❌：${*}。" >&2
}

function add_msg_block() {
  local icon title arr_ref block_header image
  declare -n arr_ref="${3}"

  icon="${1}"
  title="${2}"

  [[ "${#arr_ref[@]}" -eq 0 ]] && return

  printf -v block_header "\n<b>%s %s ( %d ):</b>" "${icon}" "${title}" "${#arr_ref[@]}"
  tg_msg_body="${tg_msg_body}${block_header}"

  for image in "${arr_ref[@]}"; do
    tg_msg_body="${tg_msg_body}\n• <code>${image}</code>"
  done
}

function main() {
  local dependencies needs_update dependency
  local success_imgs skipped_imgs failed_imgs
  local source_image image_ref target_image
  local src_digest dst_digest tg_msg_body

  dependencies=('skopeo')
  needs_update='true'

  for dependency in "${dependencies[@]}"; do
    if ! command -v "${dependency}" &>/dev/null; then
      log "缺失依赖：${dependency}，执行自动安装"
      if [[ "${needs_update}" == 'true' ]]; then
        sudo -E apt-get -qq update
        needs_update='false'
      fi
      sudo -E apt-get -qq install "${dependency}"
    fi
  done

  skopeo login -u "${DOCKER_USER:-}" -p "${DOCKER_PASS:-}" docker.io
  skopeo login -u "${REPO_OWNER:-}" -p "${GITHUB_TOKEN:-}" ghcr.io

  {
    echo "### 🔄 镜像同步任务汇总"
    echo "| 镜像 | 状态 | 详情 |"
    echo "| :--- | :--- | :--- |"
  } >>"${GITHUB_STEP_SUMMARY}"

  success_imgs=()
  skipped_imgs=()
  failed_imgs=()

  if [[ ! -f "${LIST_FILE}" ]]; then
    error "找不到列表文件：${LIST_FILE}。"
    exit 1
  fi

  while read -r source_image || [[ -n "${source_image}" ]]; do
    source_image="${source_image#"${source_image%%[![:space:]]*}"}"
    source_image="${source_image%"${source_image##*[![:space:]]}"}"
    [[ -z "${source_image}" || "${source_image}" == "#"* ]] && continue

    image_ref="${source_image##*/}"
    target_image="${TARGET_REGISTRY}/${image_ref}"

    log "正在处理：${source_image}"

    src_digest="$(skopeo inspect --format '{{.Digest}}' --retry-times 3 "docker://${source_image}" 2>/dev/null || :)"
    if [[ -z "${src_digest}" ]]; then
      echo "| ${image_ref} | ❌ 失败 | 镜像获取失败 |" >>"${GITHUB_STEP_SUMMARY}"
      failed_imgs+=("${image_ref}")
      continue
    fi

    dst_digest="$(skopeo inspect --format '{{.Digest}}' --retry-times 3 "docker://${target_image}" 2>/dev/null || echo 'none')"

    if [[ "${src_digest}" == "${dst_digest}" ]]; then
      echo "| ${image_ref} | ℹ️ 跳过 | 镜像无需更新 |" >>"${GITHUB_STEP_SUMMARY}"
      skipped_imgs+=("${image_ref}")
      continue
    fi

    if skopeo copy -aq --retry-times 3 "docker://${source_image}" "docker://${target_image}"; then
      echo "| ${image_ref} | ✅ 成功 | 镜像同步成功 |" >>"${GITHUB_STEP_SUMMARY}"
      success_imgs+=("${image_ref}")
    else
      echo "| ${image_ref} | ❌ 失败 | 镜像同步失败 |" >>"${GITHUB_STEP_SUMMARY}"
      failed_imgs+=("${image_ref}")
    fi

  done <"${LIST_FILE}"

  tg_msg_body=''
  add_msg_block '✅' '成功' success_imgs
  add_msg_block 'ℹ️' '跳过' skipped_imgs
  add_msg_block '❌' '失败' failed_imgs

  [[ -z "${tg_msg_body}" ]] && tg_msg_body="\n<b>ℹ️ 本次无同步任务执行</b>"

  {
    echo "TG_MSG<<EOF"
    printf "%b\n" "${tg_msg_body}"
    echo "EOF"
  } >>"${GITHUB_ENV}"
}

main "$@"

unset LIST_FILE TARGET_REGISTRY
unset -f log error add_msg_block main
