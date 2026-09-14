#!/usr/bin/env bash
# Explicit native-primary/alias handover. No customer DNS mutations.
source "$VESTA/func/vx/cloudflare/migration.sh"

vx_domain_connection_migration_root() { printf '%s/migrations\n' "$(vx_domain_connection_root)"; }
vx_domain_connection_migration_path() { printf '%s/%s\n' "$(vx_domain_connection_migration_root)" "$(vx_domain_connection_hash "$1/$2")"; }

vx_domain_connection_migration_validate() {
    [[ $EUID == 0 && "$1" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]] || return 1
    vx_domain_connection_hostname_valid "$2" || return 1
    [[ -d "$VESTA/data/users/$1" && ! -L "$VESTA/data/users/$1" ]] || return 1
}

vx_domain_connection_migration_execution_allowed() {
    # The approved implementation explicitly excludes these production sites.
    case "$1/$2" in
        Jack9f6fa/castlesoncommand.com.au|Jack9f6fa/nextgenerationhoardings.com.au|Jack9f6fa/newcastleslushiehire.com.au)
            vx_domain_connection_error 'named production site is excluded from execution'; return 4 ;;
    esac
}

vx_domain_connection_migration_row() {
    vx_cf_migration_exact_row "$1" "$2" || return 1
    VX_DCM_ROW=$VX_CF_MIGRATION_SOURCE_ROW
}

# Include namespace, quota, registry, provider configuration and served material.
# A changed generation or certificate therefore invalidates both apply and rollback.
vx_domain_connection_migration_service_root() { printf '/etc\n'; }

vx_domain_connection_migration_revision() {
    /usr/bin/python3 - "$VESTA" "$HOMEDIR" "$1" "$(vx_domain_connection_migration_service_root)" "${WEB_SYSTEM:-}" "${PROXY_SYSTEM:-}" <<'PY'
import hashlib,json,os,pathlib,stat,sys
v,h,u,services,web,proxy=sys.argv[1:]; paths=[pathlib.Path(v)/'conf', pathlib.Path(v)/'data/vx/cloudflare', pathlib.Path(v)/'data/vx/domain-connections/hostnames',pathlib.Path(v)/'data/vx/domain-connections/config.json',pathlib.Path(v)/'data/vx/domain-connections/target.conf',pathlib.Path(v)/f'data/users/{u}/ssl',pathlib.Path(h)/u/'conf/web']
paths+=[pathlib.Path(services)/x/'conf.d/vesta.conf' for x in sorted(set([web,proxy])) if x and x!='remote']
paths+=[pathlib.Path(v)/'data/ips']
paths+=sorted((pathlib.Path(v)/'data/users').glob('*/web.conf'))
paths+=sorted((pathlib.Path(v)/'data/users').glob('*/user.conf'))
hash=hashlib.sha256()
def add(p):
    hash.update(str(p).encode()+b'\0')
    if not p.exists() and not p.is_symlink(): hash.update(b'absent'); return
    s=p.lstat(); hash.update(f'{s.st_mode}:{s.st_uid}:{s.st_gid}'.encode())
    if stat.S_ISLNK(s.st_mode): hash.update(os.readlink(p).encode())
    elif stat.S_ISREG(s.st_mode):
        if 'domain-connections/hostnames/' in str(p) and p.suffix=='.json':
            r=json.loads(p.read_text()); keys=['VERSION','OWNER','TECHNICAL_FQDN','HOSTNAME','REQUEST_ID','CONNECTION_ID','GENERATION','PROOF_TOKEN','CLEANUP','MIGRATION']
            hash.update(json.dumps({k:r.get(k) for k in keys},sort_keys=True).encode())
        else: hash.update(p.read_bytes())
    elif stat.S_ISDIR(s.st_mode):
        for x in sorted(p.iterdir()):
            if x.name.endswith('.lock') or x.name.startswith('.'): continue
            add(x)
    else: raise SystemExit('unsupported recovery filesystem object')
for p in paths: add(p)
print(hash.hexdigest())
PY
}

vx_domain_connection_migration_assess() {
    local owner=$1 hostname=$2 row aliases revision certificate expiry='' issuer='' managed=false tls=false names quota extra dns='[]' name answer records kind
    vx_domain_connection_migration_validate "$owner" "$hostname" || return 1
    vx_domain_connection_migration_row "$owner" "$hostname" || return 1
    row=$VX_DCM_ROW
    aliases=$(vx_domain_connection_native_value "$row" ALIAS)
    names=$(jq -cn --arg h "$hostname" --arg a "$aliases" '[$h]+($a|split(",")|map(select(length>0)))')
    vx_cf_native_web_authority_preflight "$owner" "$hostname" || return 1
    [[ "$VX_CF_WEB_AUTHORITY_STATE" != managed ]] || managed=true
    certificate="$VESTA/data/users/$owner/ssl/$hostname.crt"
    if [[ -f "$certificate" && ! -L "$certificate" ]]; then
        issuer=$(openssl x509 -in "$certificate" -noout -issuer 2>/dev/null) || issuer=''
        expiry=$(openssl x509 -in "$certificate" -noout -enddate 2>/dev/null | cut -d= -f2-) || expiry=''
        if [[ $(vx_domain_connection_native_value "$row" LETSENCRYPT) == yes ]] && openssl x509 -in "$certificate" -noout -checkend 86400 >/dev/null 2>&1; then tls=true; fi
    fi
    while IFS= read -r name; do
        records='{}'
        for kind in A AAAA CNAME CAA; do
            answer=$(vx_domain_connection_dns_query "$name" "$kind" 2>/dev/null || :)
            records=$(jq -cn --argjson r "$records" --arg k "$kind" --arg a "$answer" '$r+{($k):($a|split("\n")|map(select(length>0)))}')
        done
        dns=$(jq -cn --argjson d "$dns" --arg h "$name" --argjson r "$records" '$d+[{hostname:$h,records:$r,routingAcceptance:"not_established"}]')
    done < <(jq -r '.[]' <<<"$names")
    revision=$(vx_domain_connection_migration_revision "$owner") || return 1
    quota=$(vx_domain_connection_quota_json "$owner") || return 1
    extra=$(jq 'length' <<<"$names"); [[ "$managed" != true ]] || extra=$((extra-1))
    jq -cn --arg owner "$owner" --arg hostname "$hostname" --arg revision "$revision" --argjson names "$names" --argjson managed "$managed" \
        --argjson quota "$quota" --argjson extra "$extra" --argjson tls "$tls" --arg expiry "$expiry" --arg issuer "$issuer" --arg binding "$(vx_domain_connection_hash "$row")" --argjson dns "$dns" \
        '{version:1,owner:$owner,hostname:$hostname,revision:$revision,nativePrimary:true,hostnames:$names,managed:$managed,quota:$quota,additionalNativeRows:$extra,existingLE:$tls,certificateExpiresAt:$expiry,certificateIssuer:$issuer,bindingRevision:$binding,dns:$dns,writeFree:true,sharedServiceEffects:["web and proxy configtest","shared web and proxy restart","restart of restored configuration on failure"],limitations:["DNS inventory is not routing or ownership proof","customer DNS cutover may be required","preparation validates certificate material and exact ownership"]}'
}

vx_domain_connection_migration_save() {
    local dir=$1 payload=$2 tmp
    [[ -d "$dir" && ! -L "$dir" && $(stat -c '%u:%a' "$dir") == 0:700 && ! -L "$dir/plan.json" ]] || return 1
    tmp=$(mktemp "$dir/.plan.XXXXXX") || return 1
    jq -S . <<<"$payload" >"$tmp" && chmod 600 "$tmp" && mv -fT "$tmp" "$dir/plan.json"
}

vx_domain_connection_migration_load() {
    local dir=$1 owner=$2 hostname=$3
    [[ ! -L "$dir" && $(stat -c '%u:%a' "$dir" 2>/dev/null) == 0:700 \
        && ! -L "$dir/plan.json" && $(stat -c '%u:%a' "$dir/plan.json" 2>/dev/null) == 0:600 ]] || return 1
    VX_DCM_PLAN=$(jq -ce --arg owner "$owner" --arg h "$hostname" 'select(.version==1 and .assessment.owner==$owner and .assessment.hostname==$h)' "$dir/plan.json") || return 1
    local file
    for file in manifest.sha256 native.tar rendered.tar services.tar services.list source.row; do
        vx_domain_connection_safe_path "$dir/$file" file || return 1
    done
    (cd "$dir" && sha256sum --status -c manifest.sha256) || return 1
}

vx_domain_connection_migration_certificate() {
    local owner=$1 source=$2 hostname=$3 public=$4 cert="$VESTA/data/users/$1/ssl/$2"
    local extension
    for extension in crt key pem; do [[ -f "$cert.$extension" && ! -L "$cert.$extension" ]] || return 1; done
    openssl x509 -in "$cert.crt" -noout -checkhost "$hostname" >/dev/null 2>&1 && \
        openssl x509 -in "$cert.crt" -noout -checkend 86400 >/dev/null 2>&1 || return 1
    [[ $(openssl x509 -in "$cert.crt" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum) == \
       $(openssl pkey -in "$cert.key" -pubout -outform DER 2>/dev/null | sha256sum) ]] || return 1
    if [[ "$public" == true ]]; then
        if [[ -s "$cert.ca" ]]; then openssl verify -untrusted "$cert.ca" "$cert.crt" >/dev/null 2>&1
        else openssl verify "$cert.crt" >/dev/null 2>&1; fi
    fi
}

vx_domain_connection_migration_namespace() {
    local owner=$1 source=$2 names=$3 hostname conf row d a found
    while IFS= read -r hostname; do
        [[ ! -e "$(vx_domain_connection_record_path "$hostname")" && ! -L "$(vx_domain_connection_record_path "$hostname")" ]] || return 1
        found=0
        for conf in "$VESTA"/data/users/*/web.conf; do
            while IFS= read -r row; do
                d=$(vx_domain_connection_native_value "$row" DOMAIN); a=$(vx_domain_connection_native_value "$row" ALIAS)
                if [[ "$d" == "$hostname" || ",$a," == *",$hostname,"* ]]; then
                    [[ "$conf" == "$VESTA/data/users/$owner/web.conf" && "$d" == "$source" ]] || return 1
                    found=$((found+1))
                fi
            done <"$conf"
        done
        [[ "$found" == 1 ]] || return 1
    done < <(jq -r '.[]' <<<"$names")
}

# All names stay locked until the enclosing operation subshell exits. Native
# subprocesses receive the exact selected hostname descriptor as their capability.
vx_domain_connection_migration_lock_names() {
    local name
    while IFS= read -r name; do
        vx_domain_connection_hostname_valid "$name" || return 1
        vx_domain_connection_lock "$name" || return 1
        VX_DCM_HOST_LOCKS[$name]=$VX_DOMAIN_CONNECTION_LOCK_FD
    done < <(jq -r '.[]' <<<"$1" | LC_ALL=C sort -u)
}

vx_domain_connection_migration_select_lock() {
    [[ -n "${VX_DCM_HOST_LOCKS[$1]:-}" ]] || return 1
    VX_DOMAIN_CONNECTION_LOCK_FD=${VX_DCM_HOST_LOCKS[$1]}
    export VX_DOMAIN_CONNECTION_LOCK_FD
}

vx_domain_connection_migration_prepare() (
    local owner=$1 hostname=$2 dir assessment names name row managed public available extra token payload service root
    declare -A VX_DCM_HOST_LOCKS=()
    vx_domain_connection_migration_validate "$owner" "$hostname" && vx_domain_connection_migration_execution_allowed "$owner" "$hostname" || return 1
    vx_domain_connection_prepare && vx_domain_connection_owner_lock "$owner" || return 1
    dir=$(vx_domain_connection_migration_path "$owner" "$hostname")
    [[ ! -e "$dir" && ! -L "$dir" ]] || { vx_domain_connection_error 'preparation already exists; apply or roll back its exact revision'; return 9; }
    [[ -z "${VESTA_WEB_CONF_CHANGE_TRIGGER:-}" ]] || { vx_domain_connection_error 'web-config trigger cannot guarantee a deferred cutover'; return 1; }
    [[ -z "${WEB_BACKEND:-}" || "${WEB_BACKEND_POOL:-}" == user ]] || { vx_domain_connection_error 'per-domain backend pools need separately prepared backend recovery'; return 1; }
    assessment=$(vx_domain_connection_migration_assess "$owner" "$hostname") || return 1
    names=$(jq -c .hostnames <<<"$assessment")
    vx_domain_connection_migration_lock_names "$names" || return 1
    [[ $(vx_domain_connection_migration_revision "$owner") == "$(jq -r .revision <<<"$assessment")" ]] || return 9
    managed=$(jq -r .managed <<<"$assessment")
    vx_domain_connection_migration_row "$owner" "$hostname" || return 1; row=$VX_DCM_ROW
    [[ $(vx_domain_connection_native_value "$row" PROXY) == vx-proxy && $(vx_domain_connection_native_value "$row" PROXY_MODE) == proxy \
        && $(vx_domain_connection_native_value "$row" SUSPENDED) == no && -z $(vx_domain_connection_native_value "$row" VX_CONNECTION_ID) ]] || return 1
    [[ "$managed" == true || $(vx_domain_connection_native_value "$row" LETSENCRYPT) == yes ]] || return 1
    vx_domain_connection_migration_namespace "$owner" "$hostname" "$names" || return 10
    available=$(jq -r '.quota.available // "null"' <<<"$assessment"); extra=$(jq -r .additionalNativeRows <<<"$assessment")
    [[ "$available" == null ]] || ((available >= extra)) || return 11
    public=true; [[ "$managed" != true ]] || public=false
    while IFS= read -r name; do
        vx_domain_connection_migration_execution_allowed "$owner" "$name" && vx_domain_connection_hostname_valid "$name" && vx_domain_connection_migration_certificate "$owner" "$hostname" "$name" "$public" || return 1
    done < <(jq -r '.[]' <<<"$names")
    [[ "$managed" != true ]] || names=$(jq -c --arg h "$hostname" 'map(select(.!=$h))' <<<"$names")
    [[ $(jq length <<<"$names") -gt 0 ]] || return 1
    # Private snapshots retain exact served certificates/configuration and counters.
    [[ ! -L "$(vx_domain_connection_migration_root)" ]] || return 1
    install -d -m 0700 "$(vx_domain_connection_migration_root)" "$dir" || return 1
    umask 077
    tar -C "$VESTA/data/users/$owner" -cpf "$dir/native.tar" web.conf user.conf ssl || return 1
    tar -C "$HOMEDIR/$owner/conf" -cpf "$dir/rendered.tar" web || return 1
    root=$(vx_domain_connection_migration_service_root)
    printf '%s\n' "$WEB_SYSTEM" "$PROXY_SYSTEM" | sort -u | while read -r service; do
        [[ -n "$service" && "$service" != remote ]] || continue
        [[ "$service" =~ ^[a-zA-Z0-9_-]+$ && -f "$root/$service/conf.d/vesta.conf" && ! -L "$root/$service/conf.d/vesta.conf" ]] || exit 1
        printf '%s/conf.d/vesta.conf\n' "$service"
    done >"$dir/services.list" || return 1
    tar -C "$root" -cpf "$dir/services.tar" -T "$dir/services.list" || return 1
    printf '%s\n' "$row" >"$dir/source.row"
    (cd "$dir" && sha256sum native.tar rendered.tar services.tar services.list source.row >manifest.sha256) || return 1
    token=$(openssl rand -hex 24) || return 1
    payload=$(jq -cn --argjson a "$assessment" --argjson names "$names" --arg token "$token" \
        '{version:1,state:"prepared",assessment:$a,names:$names,token:$token,technicalFQDN:(if $a.managed then $a.hostname else null end),expectedRevision:$a.revision,originRetired:false}') || return 1
    vx_domain_connection_migration_save "$dir" "$payload" || return 1
    jq '{version,state,revision:.expectedRevision,hostnames:.names,technicalFQDN}' <<<"$payload"
)

vx_domain_connection_migration_status() {
    local owner=$1 hostname=$2 dir current
    vx_domain_connection_migration_validate "$owner" "$hostname" || return 1
    dir=$(vx_domain_connection_migration_path "$owner" "$hostname")
    vx_domain_connection_migration_load "$dir" "$owner" "$hostname" || return 1
    current=$(vx_domain_connection_migration_revision "$owner") || return 1
    jq --arg current "$current" '{version,state,technicalFQDN,hostnames:.names,preparedRevision:.assessment.revision,expectedRevision,currentRevision:$current,drift:($current!=.expectedRevision),originRetired}' <<<"$VX_DCM_PLAN"
}

vx_domain_connection_migration_checkpoint() {
    local dir=$1 state=$2 revision
    revision=$(vx_domain_connection_migration_revision "$VX_DCM_OWNER") || return 1
    VX_DCM_PLAN=$(jq --arg s "$state" --arg r "$revision" '.state=$s|.expectedRevision=$r' <<<"$VX_DCM_PLAN") || return 1
    vx_domain_connection_migration_save "$dir" "$VX_DCM_PLAN"
}

# Native rows may contain private upstream headers. Feed row material through
# stdin, never awk/sed/python arguments visible in the process table.
vx_domain_connection_migration_replace_row() {
    local file=$1 old=$2 replacement=$3
    printf '%s\0%s\0' "$old" "$replacement" | /usr/bin/python3 -c '
import os,pathlib,stat,sys,tempfile
p=pathlib.Path(sys.argv[1]); old,new,empty=sys.stdin.buffer.read().split(b"\0")
s=p.lstat()
if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1: raise SystemExit(1)
rows=p.read_bytes().splitlines(keepends=True)
if sum(r.rstrip(b"\n")==old for r in rows)!=1: raise SystemExit(1)
fd,name=tempfile.mkstemp(prefix=".migration-row.",dir=p.parent)
try:
    with os.fdopen(fd,"wb") as f:
        f.write(b"".join(new+b"\n" if r.rstrip(b"\n")==old else r for r in rows))
        f.flush(); os.fsync(f.fileno()); os.fchmod(f.fileno(),stat.S_IMODE(s.st_mode)); os.fchown(f.fileno(),s.st_uid,s.st_gid)
    os.replace(name,p)
finally:
    if os.path.exists(name): os.unlink(name)
' "$file"
}

vx_domain_connection_migration_set_row() {
    local owner=$1 hostname=$2 original=$3 key value row=$3
    shift 3
    while (($#)); do
        key=$1 value=$2; shift 2
        if vx_cf_migration_row_value "$row" "$key"; then vx_cf_migration_row_replace "$row" "$key" "$value" || return 1; row=$VX_CF_MIGRATION_ROW
        else [[ "$value" != *"'"* && "$value" != *$'\n'* ]] || return 1; row+=" $key='$value'"; fi
    done
    vx_domain_connection_migration_replace_row "$VESTA/data/users/$owner/web.conf" "$original" "$row"
}

vx_domain_connection_migration_binding() {
    local owner=$1 hostname=$2 source=$3 original key value
    vx_domain_connection_migration_row "$owner" "$hostname" || return 1; original=$VX_DCM_ROW
    local -a fields=()
    for key in IP TPL BACKEND PROXY PROXY_EXT PROXY_MODE PROXY_TARGET PROXY_PRESERVE_HOST PROXY_PROFILE PROXY_TIMEOUT PROXY_HEADERS PROXY_PATH; do
        value=$(vx_domain_connection_native_value "$source" "$key"); fields+=("$key" "$value")
    done
    vx_domain_connection_migration_set_row "$owner" "$hostname" "$original" "${fields[@]}"
}

vx_domain_connection_migration_record() {
    local owner=$1 technical=$2 hostname=$3 token=$4 now
    now=$(vx_domain_connection_now)
    jq -cn --arg owner "$owner" --arg t "$technical" --arg h "$hostname" --arg token "$token" --arg now "$now" \
        --arg id "$(vx_domain_connection_hash "$token/$hostname")" \
        '{VERSION:1,OWNER:$owner,TECHNICAL_FQDN:$t,HOSTNAME:$h,REQUEST_ID:("migration:"+$token),CONNECTION_ID:$id,GENERATION:1,PROOF_TOKEN:$token,PROOF_EXPIRES_AT:$now,STATE:"pending_tls",REASON:"migration_in_progress",CREATED_AT:$now,LAST_CHECKED_AT:null,LAST_SUCCESSFUL_AT:null,NEXT_CHECK_AT:null,OBSERVATIONS:{},CLEANUP:{NATIVE_CHILD:false},MIGRATION:{ADOPTED:true}}'
}

vx_domain_connection_migration_copy_certificate() {
    local owner=$1 source=$2 target=$3 ext from
    for ext in crt key pem ca; do
        from="$VESTA/data/users/$owner/ssl/$source.$ext"
        [[ -f "$from" ]] || { [[ "$ext" == ca ]] && continue; return 1; }
        [[ "$source" == "$target" ]] || cp -p -- "$from" "$VESTA/data/users/$owner/ssl/$target.$ext" || return 1
        cp -p -- "$from" "$HOMEDIR/$owner/conf/web/ssl.$target.$ext" || return 1
    done
}

vx_domain_connection_migration_render_parent() (
    local user=$1 domain=$2 USER_DATA="$VESTA/data/users/$1"
    source "$VESTA/func/domain.sh"
    get_domain_values web
    local_ip=$(get_real_ip "$IP")
    prepare_web_domain_values
    add_web_config "$WEB_SYSTEM" "$TPL.tpl" && add_web_config "$PROXY_SYSTEM" "$PROXY.tpl" || return 1
    if [[ "$SSL" == yes ]]; then
        add_web_config "$WEB_SYSTEM" "$TPL.stpl" && add_web_config "$PROXY_SYSTEM" "$PROXY.stpl" || return 1
    fi
)

vx_domain_connection_migration_handover() {
    local dir=$1 owner=$VX_DCM_OWNER source=$VX_DCM_HOSTNAME technical source_row names name record path original id public managed
    source_row=$(cat "$dir/source.row") || return 1
    technical=$(jq -r '.technicalFQDN // empty' <<<"$VX_DCM_PLAN")
    managed=$(jq -r .assessment.managed <<<"$VX_DCM_PLAN")
    names=$(jq -c .names <<<"$VX_DCM_PLAN")
    if [[ -z "$technical" ]]; then
        # Persist allocation intent before the provider/native command. A lost
        # allocator response is recovery_required, never a second allocation.
        vx_domain_connection_migration_checkpoint "$dir" allocating || return 1
        technical=$("$BIN/v-add-vx-managed-web-domain" "$owner" "$(vx_domain_connection_native_value "$source_row" IP)" no none \
            "$(vx_domain_connection_native_value "$source_row" PROXY_EXT)" 2>/dev/null) || return 1
        vx_domain_connection_hostname_valid "$technical" && vx_cf_load_metadata "$owner" "$technical" || return 1
        VX_DCM_PLAN=$(jq --arg t "$technical" '.technicalFQDN=$t' <<<"$VX_DCM_PLAN") || return 1
        vx_domain_connection_migration_checkpoint "$dir" transferring || return 1
        vx_domain_connection_migration_binding "$owner" "$technical" "$source_row" || return 1
    fi
    # Reserve every hostname before removing any alias. Owner lock covers the
    # entire batch; the worker also acquires it before native operations.
    while IFS= read -r name; do
        record=$(vx_domain_connection_migration_record "$owner" "$technical" "$name" "$(jq -r .token <<<"$VX_DCM_PLAN")") || return 1
        vx_domain_connection_record_write "$name" "$record" || return 1
    done < <(jq -r '.[]' <<<"$names")
    vx_domain_connection_migration_row "$owner" "$source" || return 1
    vx_domain_connection_migration_set_row "$owner" "$source" "$VX_DCM_ROW" ALIAS '' || return 1
    while IFS= read -r name; do
        vx_domain_connection_migration_select_lock "$name" || return 1
        path=$(vx_domain_connection_record_path "$name")
        vx_domain_connection_native_context "$path" && vx_domain_connection_native_parent_binding || return 1
        if [[ "$name" != "$source" ]]; then
            export VX_DOMAIN_CONNECTION_RECORD="$path" VX_DOMAIN_CONNECTION_NATIVE_CREATE=1
            "$BIN/v-add-web-domain" "$owner" "$name" "$VX_DC_PARENT_IP" no none "$VX_DC_PARENT_PROXY_EXT" >/dev/null 2>&1 || return 1
        fi
        vx_domain_connection_migration_binding "$owner" "$name" "$source_row" || return 1
        vx_domain_connection_migration_row "$owner" "$name" || return 1; original=$VX_DCM_ROW
        id=$(jq -r .CONNECTION_ID "$path")
        vx_domain_connection_migration_set_row "$owner" "$name" "$original" VX_CONNECTION_ID "$id" \
            VX_CONNECTION_PARENT "$technical" VX_CONNECTION_GENERATION 1 SSL yes SSL_HOME "$(vx_domain_connection_native_value "$source_row" SSL_HOME)" LETSENCRYPT "$(vx_domain_connection_native_value "$source_row" LETSENCRYPT)" || return 1
        vx_domain_connection_migration_copy_certificate "$owner" "$source" "$name" || return 1
        vx_domain_connection_native_record_load "$path" && vx_domain_connection_native_render || return 1
    done < <(jq -r '.[]' <<<"$names")
    # Remove the old alias render before the sole accepted cutover; the running
    # old configuration remains intact until this complete configtest/restart.
    vx_domain_connection_migration_render_parent "$owner" "$technical" || return 1
    "$BIN/v-update-user-counters" "$owner" >/dev/null 2>&1 || return 1
    vx_domain_connection_native_configtest && vx_domain_connection_native_restart || return 1
    vx_domain_connection_migration_checkpoint "$dir" certifying || return 1
    while IFS= read -r name; do
        vx_domain_connection_migration_select_lock "$name" || return 1
        path=$(vx_domain_connection_record_path "$name")
        if [[ "$managed" == true ]]; then
            vx_domain_connection_native_issue "$path" || return 1
        fi
        public=$(vx_domain_connection_native_observe "$path") || return 1
        jq -e '.TLS_STATE=="accepted" and .HTTPS_IDENTITY==true and .CONFIG_VALID==true' >/dev/null <<<"$public" || return 1
        # Public ingress/SNI acceptance is separate from customer DNS cutover.
        vx_domain_connection_worker_update "$name" 1 degraded migration_dns_cutover_check \
            "$(jq -cn --argjson native "$public" '{native:$native}')" false || return 1
    done < <(jq -r '.[]' <<<"$names")
    vx_domain_connection_migration_checkpoint "$dir" applied
}

vx_domain_connection_migration_apply() (
    local owner=$1 hostname=$2 supplied=${3:-} dir actual rc=0
    declare -A VX_DCM_HOST_LOCKS=()
    vx_domain_connection_migration_validate "$owner" "$hostname" && vx_domain_connection_migration_execution_allowed "$owner" "$hostname" || return 1
    vx_domain_connection_owner_lock "$owner" || return 1
    dir=$(vx_domain_connection_migration_path "$owner" "$hostname")
    vx_domain_connection_migration_load "$dir" "$owner" "$hostname" || return 1
    VX_DCM_OWNER=$owner VX_DCM_HOSTNAME=$hostname
    vx_domain_connection_migration_lock_names "$(jq -c .assessment.hostnames <<<"$VX_DCM_PLAN")" || return 1
    [[ -n "$supplied" && "$supplied" == "$(jq -r .assessment.revision <<<"$VX_DCM_PLAN")" ]] || return 9
    actual=$(vx_domain_connection_migration_revision "$owner") || return 1
    [[ "$actual" == "$(jq -r .expectedRevision <<<"$VX_DCM_PLAN")" ]] || return 9
    case "$(jq -r .state <<<"$VX_DCM_PLAN")" in applied) return 0;; prepared) ;; *) return 9;; esac
    vx_domain_connection_migration_checkpoint "$dir" applying || return 1
    vx_domain_connection_migration_handover "$dir" || rc=$?
    if ((rc)); then
        vx_domain_connection_migration_checkpoint "$dir" recovery_required || return 1
        vx_domain_connection_migration_restore "$dir" || return 1
        return "$rc"
    fi
    jq '{version,state,technicalFQDN,hostnames:.names,dnsCutover:"check_required",originSANRetirement:"explicit_finalize_after_readiness"}' <<<"$VX_DCM_PLAN"
)

vx_domain_connection_migration_restore() {
    local dir=$1 owner=$VX_DCM_OWNER source=$VX_DCM_HOSTNAME name technical state record
    [[ $(vx_domain_connection_migration_revision "$owner") == "$(jq -r .expectedRevision <<<"$VX_DCM_PLAN")" ]] || return 9
    [[ $(jq -r .originRetired <<<"$VX_DCM_PLAN") == false ]] || { vx_domain_connection_error 'Origin CA retirement is irreversible; use forward repair'; return 9; }
    technical=$(jq -r '.technicalFQDN // empty' <<<"$VX_DCM_PLAN")
    # An interrupted allocator without exact returned identity is never guessed.
    [[ -n "$technical" ]] || { vx_domain_connection_error 'allocation identity needs read-only operator recovery'; return 9; }
    vx_domain_connection_migration_checkpoint "$dir" rolling_back || return 1
    while IFS= read -r name; do
        record=$(vx_domain_connection_record_read "$name" 2>/dev/null || :)
        if [[ -n "$record" ]]; then
            jq -e --arg token "$(jq -r .token <<<"$VX_DCM_PLAN")" '.REQUEST_ID==("migration:"+$token) and .GENERATION==1' >/dev/null <<<"$record" || return 9
            # Remove only the exact migration reservation; native deletion uses
            # marker protection, so restore the old authority from the snapshot.
            rm -- "$(vx_domain_connection_record_path "$name")" || return 1
        fi
    done < <(jq -r '.names[]' <<<"$VX_DCM_PLAN")
    if [[ $(jq -r .assessment.managed <<<"$VX_DCM_PLAN") == false ]]; then
        "$BIN/v-delete-vx-cloudflare-web-domain" "$owner" "$technical" >/dev/null 2>&1 || {
            vx_domain_connection_migration_checkpoint "$dir" recovery_required; return 1;
        }
    fi
    # Rollback is admitted by a complete fingerprint. Restore just the protected
    # configuration trees; never delete site content or broadly clean workloads.
    rm -rf -- "$VESTA/data/users/$owner/ssl" "$HOMEDIR/$owner/conf/web" || return 1
    tar -C "$VESTA/data/users/$owner" -xpf "$dir/native.tar" && tar -C "$HOMEDIR/$owner/conf" -xpf "$dir/rendered.tar" || return 1
    tar -C "$(vx_domain_connection_migration_service_root)" -xpf "$dir/services.tar" || return 1
    "$BIN/v-update-sys-ip-counters" "$(vx_domain_connection_native_value "$(cat "$dir/source.row")" IP)" >/dev/null 2>&1 || return 1
    vx_domain_connection_native_configtest && vx_domain_connection_native_restart || {
        vx_domain_connection_migration_checkpoint "$dir" recovery_required; return 1;
    }
    vx_domain_connection_migration_checkpoint "$dir" rolled_back
}

vx_domain_connection_migration_rollback() (
    local owner=$1 hostname=$2 supplied=${3:-} dir
    declare -A VX_DCM_HOST_LOCKS=()
    vx_domain_connection_migration_validate "$owner" "$hostname" && vx_domain_connection_migration_execution_allowed "$owner" "$hostname" || return 1
    vx_domain_connection_owner_lock "$owner" || return 1
    dir=$(vx_domain_connection_migration_path "$owner" "$hostname")
    vx_domain_connection_migration_load "$dir" "$owner" "$hostname" || return 1
    VX_DCM_OWNER=$owner VX_DCM_HOSTNAME=$hostname
    vx_domain_connection_migration_lock_names "$(jq -c .assessment.hostnames <<<"$VX_DCM_PLAN")" || return 1
    [[ -n "$supplied" && "$supplied" == "$(jq -r .expectedRevision <<<"$VX_DCM_PLAN")" && "$supplied" == "$(vx_domain_connection_migration_revision "$owner")" ]] || return 9
    case "$(jq -r .state <<<"$VX_DCM_PLAN")" in
        rolled_back) return 0;; prepared) vx_domain_connection_migration_checkpoint "$dir" rolled_back;;
        applied|recovery_required|rolling_back) vx_domain_connection_migration_restore "$dir";; *) return 9;;
    esac
)

vx_domain_connection_migration_finalize() (
    local owner=$1 hostname=$2 supplied=${3:-} dir name record result
    declare -A VX_DCM_HOST_LOCKS=()
    vx_domain_connection_migration_validate "$owner" "$hostname" && vx_domain_connection_migration_execution_allowed "$owner" "$hostname" || return 1
    vx_domain_connection_owner_lock "$owner" || return 1
    dir=$(vx_domain_connection_migration_path "$owner" "$hostname")
    vx_domain_connection_migration_load "$dir" "$owner" "$hostname" || return 1
    VX_DCM_OWNER=$owner VX_DCM_HOSTNAME=$hostname
    vx_domain_connection_migration_lock_names "$(jq -c .assessment.hostnames <<<"$VX_DCM_PLAN")" || return 1
    [[ "$supplied" == "$(jq -r .expectedRevision <<<"$VX_DCM_PLAN")" && \
        "$supplied" == "$(vx_domain_connection_migration_revision "$owner")" ]] || return 9
    case "$(jq -r .state <<<"$VX_DCM_PLAN")" in
        finalized) return 0;; applied) ;;
        recovery_required|retiring_origin) [[ $(jq -r .originRetired <<<"$VX_DCM_PLAN") == true ]] || return 9;;
        *) return 9;;
    esac
    [[ $(jq -r .assessment.managed <<<"$VX_DCM_PLAN") == true ]] || return 0
    while IFS= read -r name; do
        record=$(vx_domain_connection_record_read "$name") || return 1
        [[ $(jq -r .STATE <<<"$record") == connected ]] || return 1
        result=$(vx_domain_connection_native_observe "$(vx_domain_connection_record_path "$name")") || return 1
        jq -e '.TLS_STATE=="accepted" and .HTTPS_IDENTITY==true and .CONFIG_VALID==true' >/dev/null <<<"$result" || return 1
    done < <(jq -r '.names[]' <<<"$VX_DCM_PLAN")
    # Origin reconcile may revoke the prior certificate. Record that point of no
    # return BEFORE invoking it, including partial cleanup/response loss.
    VX_DCM_PLAN=$(jq '.originRetired=true' <<<"$VX_DCM_PLAN") || return 1
    vx_domain_connection_migration_checkpoint "$dir" retiring_origin || return 1
    vx_cf_origin_reconcile "$owner" "$hostname" now || { vx_domain_connection_migration_checkpoint "$dir" recovery_required; return 1; }
    vx_domain_connection_migration_checkpoint "$dir" finalized
)
