#!/usr/bin/env bash

. <(curl -fsSL "$BASH_LIB") || exit 1

msg_add() {
  local -n list_ref=$2 msg_ref=$3
  local msg_title=$1 msg_str item

  ((${#list_ref[@]})) || return 0

  printf -v msg_str '\n<b>%s（ %d ）：</b>' "$msg_title" "${#list_ref[@]}"
  msg_ref+=$msg_str

  for item in "${list_ref[@]}"; do
    msg_ref+=$'\n'"• <code>$item</code>"
  done
}

main() {
  local succ_list skip_list fail_list img_raw img_list img_row \
    img_path src_img dst_img src_dig dst_dig msg_body

  lib::need_f "$CONF_FILE"
  succ_list=() skip_list=() fail_list=()
  printf '%s\n' '### 🔄 同步汇总' '| 镜像 | 状态 |' '| :--- | :--- |' >>"$GITHUB_STEP_SUMMARY"

  skopeo login -u "$DOCKER_USER" -p "$DOCKER_TOKEN" docker.io
  skopeo login -u "$REPO_OWNER" -p "$GITHUB_TOKEN" ghcr.io

  mapfile -t img_raw <"$CONF_FILE"
  lib::tidy img_raw img_list

  for img_row in "${img_list[@]}"; do
    img_path=${img_row##*/}
    src_img=docker://$img_row
    dst_img=docker://ghcr.io/$REPO_OWNER/$img_path

    lib::log_inf "开始同步：$img_path"

    src_dig=$(skopeo inspect --format '{{.Digest}}' --retry-times 3 "$src_img" || :)
    [[ $src_dig ]] || {
      printf '| %s | ❌ 失败 |\n' "$img_path"
      fail_list+=("$img_path")
      continue
    }

    dst_dig=$(skopeo inspect --format '{{.Digest}}' --retry-times 3 "$dst_img" || :)
    [[ $src_dig == "$dst_dig" ]] && {
      printf '| %s | ℹ️ 跳过 |\n' "$img_path"
      skip_list+=("$img_path")
      continue
    }

    if skopeo copy -aq --retry-times 3 "$src_img" "$dst_img"; then
      printf '| %s | ✅ 成功 |\n' "$img_path"
      succ_list+=("$img_path")
    else
      printf '| %s | ❌ 失败 |\n' "$img_path"
      fail_list+=("$img_path")
    fi
  done >>"$GITHUB_STEP_SUMMARY"

  [[ $F_NTFY == true ]] || ((${#succ_list[@]} || ${#fail_list[@]})) || return 0

  msg_add '✅ 成功' succ_list msg_body
  msg_add 'ℹ️ 跳过' skip_list msg_body
  msg_add '❌ 失败' fail_list msg_body

  printf '%s\n' 'msg<<EOF' "$msg_body" 'EOF' >>"$GITHUB_OUTPUT"
}

main "$@"
