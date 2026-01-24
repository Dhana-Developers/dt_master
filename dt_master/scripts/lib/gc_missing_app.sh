gc_missing_app() {
    local app="$1"
    local bench="$2"

    local found="false"

    for site in "$bench"/sites/*; do
        site="$(basename "$site")"
        [[ -f "$bench/sites/$site/apps.txt" ]] || continue

        if grep -qx "$app" "$bench/sites/$site/apps.txt"; then
            sed -i "/^${app}$/d" "$bench/sites/$site/apps.txt"
            log "gc_removed_from_site=$site app=$app"
            found="true"
        fi
    done

    local cfg="$bench/sites/common_site_config.json"
    if [[ -f "$cfg" ]] && grep -q "\"$app\"" "$cfg"; then
        python3 - <<EOF
import json
p="$cfg"
with open(p) as f:
    d=json.load(f)
apps=d.get("installed_apps")
if isinstance(apps,list) and "$app" in apps:
    apps.remove("$app")
    d["installed_apps"]=apps
    with open(p,"w") as f:
        json.dump(d,f,indent=2)
EOF
        log "gc_removed_from_common_site_config app=$app"
        found="true"
    fi

    echo "$found"
}