# Ortak test yardımcıları. GEÇİCİ üretilmiş test anahtarı kullanılır; gerçek anahtara (~/.ssh/...) hiç dokunulmaz; ağ yok.

setup_repo() {
    T="$(mktemp -d)"
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ssh-keygen -q -t ed25519 -N "" -C test -f "$T/key"
    ssh-keygen -q -t ed25519 -N "" -C other -f "$T/other"
    R="$T/repo"
    mkdir -p "$R/scripts" "$T/bin" "$T/arch"
    cp "$ROOT/scripts/index-publish.sh" "$ROOT/scripts/index_lib.py" "$R/scripts/"
    cp "$ROOT/.gitignore" "$R/"
    printf 'sshpocket-index namespaces="sshpocket-index" %s\n' "$(cut -d' ' -f1,2 "$T/key.pub")" > "$R/index_signers"
    git -C "$R" init -q -b main
    git -C "$R" config user.email t@example.com
    git -C "$R" config user.name test
    git -C "$R" add -A
    git -C "$R" commit -q -m init
    # sahte gh: varsayılan = ağ yok (başarısız). Test GH_DIGEST ile digest döndürtebilir.
    cat > "$T/bin/gh" <<'GH'
#!/bin/sh
if [ -n "${GH_DIGEST:-}" ]; then echo "$GH_DIGEST"; exit 0; fi
exit 1
GH
    chmod +x "$T/bin/gh"
    export PATH="$T/bin:$PATH"
    export INDEX_SIGNING_KEY="$T/key"
    unset PAKET_SIGNING_KEY SSH_AUTH_SOCK GH_DIGEST || true
    PUBLISH="$R/scripts/index-publish.sh"
}

teardown_repo() { rm -rf "$T"; }

# mkpkg <id> <sürüm> [imza-anahtarı] [imza-ad-alanı] -> $T/arch/<id>-<sürüm>.tar.gz(.sig)
mkpkg() {
    local id="$1" ver="$2" key="${3:-$T/key}" ns="${4:-sshpocket-component}" d="$T/src/$1-$2"
    mkdir -p "$d"
    printf '{"id":"%s","version":"%s","profiles":[{"id":"ubuntu-26.04","status":"supported"},{"id":"debian-13","status":"planned"}]}\n' "$id" "$ver" > "$d/component.json"
    echo "$ver" > "$d/VERSION"
    tar -czf "$T/arch/$id-$ver.tar.gz" -C "$T/src" "$id-$ver"
    rm -f "$T/arch/$id-$ver.tar.gz.sig"
    ssh-keygen -q -Y sign -f "$key" -n "$ns" "$T/arch/$id-$ver.tar.gz"
}

# mkpkg_cj <id> <sürüm> <component.json-içeriği>: component.json bilerek farklı
mkpkg_cj() {
    local id="$1" ver="$2" d="$T/src/$1-$2"
    mkdir -p "$d"
    printf '%s\n' "$3" > "$d/component.json"
    tar -czf "$T/arch/$id-$ver.tar.gz" -C "$T/src" "$id-$ver"
    rm -f "$T/arch/$id-$ver.tar.gz.sig"
    ssh-keygen -q -Y sign -f "$T/key" -n sshpocket-component "$T/arch/$id-$ver.tar.gz"
}

# pub <id> <sürüm> [ek seçenekler...]: add (yerel arşiv + imza ile)
padd() {
    local id="$1" ver="$2"; shift 2
    "$PUBLISH" add "$id" "$ver" "syhgorath/$id" --archive "$T/arch/$id-$ver.tar.gz" --sig "$T/arch/$id-$ver.tar.gz.sig" "$@"
}

jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); 
for k in sys.argv[2:]: d=d[k]
print(d)' "$@"; }

snapshot() { (cd "$R" && git rev-parse HEAD && git status --porcelain --ignored && ls -A | sort && cat index.pending.json index.json index.json.sig 2>/dev/null || true); }
