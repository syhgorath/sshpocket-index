#!/usr/bin/env bash
# index-publish.sh - imzalı paket indeksinin YAYIN tarafı (bakımcı aracı, yerelde çalışır). Biçim/kurallar: sshpocket docs/package-index.md.
#
#   index-publish.sh <id> <sürüm> <sahip/depo> [seçenekler]   # add + sign (tek paket, tek komut)
#   index-publish.sh add  <id> <sürüm> <sahip/depo> [seçenekler]   # taslağa ekler (index.pending.json); özel anahtar GEREKMEZ, yalnız .pub
#   index-publish.sh sign                                      # taslağı birleştirir, seri+1, imzalar, kendini doğrular, yerel commit
#   index-publish.sh refresh                                   # içerik aynı, seri+1, yeni valid_until, imzalar, commit
#
# Seçenekler: --archive YOL --sig YOL (ikisi birlikte; yoksa GitHub Release'ten indirilir), --requires-sshpocket X.Y.Z,
#   --platforms a,b,c (yoksa component.json'daki supported profiller), --valid-days N (1..90, varsayılan 60), --yes (onay sorma), --dry-run (hiçbir şey yazmaz).
# Anahtar: INDEX_SIGNING_KEY (yoksa PAKET_SIGNING_KEY); aynı yolda .pub bulunmalı. Betik PAROLAYI/özel anahtarı HİÇ OKUMAZ: ssh-keygen kendisi sorar
# (anahtar ssh-agent'ta yüklüyse ve .pub eşleşiyorsa agent kullanılır). Push/etiket YAPMAZ; sonunda tek satır push komutu yazdırır.
set -euo pipefail

die() { echo "HATA: $*" >&2; exit 1; }
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SELF_DIR/.." && pwd)
LIB="$SELF_DIR/index_lib.py"
ORIG_PWD=$PWD
cd "$REPO_DIR"

PKG_NS="sshpocket-component"
INDEX_NS="sshpocket-index"
DRY=0; YES=0; ARCHIVE=""; SIG=""; REQUIRES=""; PLATFORMS=""; DAYS=60
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --yes) YES=1 ;;
        --archive) [ $# -ge 2 ] || die "--archive için değer yok"; ARCHIVE="$2"; shift ;;
        --sig) [ $# -ge 2 ] || die "--sig için değer yok"; SIG="$2"; shift ;;
        --requires-sshpocket) [ $# -ge 2 ] || die "--requires-sshpocket için değer yok"; REQUIRES="$2"; shift ;;
        --platforms) [ $# -ge 2 ] || die "--platforms için değer yok"; PLATFORMS="$2"; shift ;;
        --valid-days) [ $# -ge 2 ] || die "--valid-days için değer yok"; DAYS="$2"; shift ;;
        -h|--help) sed -n 2,13p "$0"; exit 0 ;;
        -*) die "bilinmeyen seçenek: $1" ;;
        *) POS+=("$1") ;;
    esac
    shift
done
[ "${#POS[@]}" -gt 0 ] || die "komut yok (add | sign | refresh | <id> <sürüm> <sahip/depo>); yardım: --help"

command -v python3 >/dev/null || die "python3 yok"
command -v ssh-keygen >/dev/null || die "ssh-keygen yok"
command -v git >/dev/null || die "git yok"
[ -f "$LIB" ] || die "yardımcı yok: $LIB"
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] && [ "$DAYS" -le 90 ] || die "--valid-days 1..90 olmalı: '$DAYS'"
[ -z "$REQUIRES" ] || [[ "$REQUIRES" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--requires-sshpocket X.Y.Z olmalı: '$REQUIRES'"
[ -z "$PLATFORMS" ] || [[ "$PLATFORMS" =~ ^[a-z0-9][a-z0-9._-]*(,[a-z0-9][a-z0-9._-]*)*$ ]] || die "--platforms virgüllü kimlik listesi olmalı: '$PLATFORMS'"
{ [ -z "$ARCHIVE" ] && [ -z "$SIG" ]; } || { [ -n "$ARCHIVE" ] && [ -n "$SIG" ]; } || die "--archive ve --sig birlikte verilmeli"

# göreli --archive/--sig, betiğin çağrıldığı dizine göre verilir (depo dizinine geçtikten sonra da doğru kalsın)
case "$ARCHIVE" in ""|/*) ;; *) ARCHIVE="$ORIG_PWD/$ARCHIVE" ;; esac
case "$SIG" in ""|/*) ;; *) SIG="$ORIG_PWD/$SIG" ;; esac

PENDING="index.pending.json"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/index-publish.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

lib() { python3 -I "$LIB" "$@"; }
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
say_dry() { if [ "$DRY" = 1 ]; then echo "[dry-run] $*"; fi; }

confirm() {
    [ "$YES" = 1 ] && return 0
    local ans=""
    read -r -p "$1 [y/N] " ans </dev/tty 2>/dev/null || ans=""
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "iptal edildi (etkileşimsiz kullanımda --yes verin)"
}

# Depo temiz, main'de ve uzakla ff-only uyumlu mu (uzak yoksa ya da uzakta main henüz yoksa atlanır: ilk yayın).
preflight_repo() {
    git rev-parse --git-dir >/dev/null 2>&1 || die "$REPO_DIR bir git deposu değil"
    [ "$(git symbolic-ref --short -q HEAD || true)" = "main" ] || die "main dalında değilsiniz"
    [ -z "$(git status --porcelain -- . ":!$PENDING")" ] || die "çalışma alanı temiz değil (commit edilmemiş değişiklik var)"
    if [ ! -s index_signers ] || ! grep -qE '^[^#[:space:]].*ssh-' index_signers; then die "index_signers yok ya da anahtar içermiyor"; fi
    if git remote get-url origin >/dev/null 2>&1; then
        if git fetch -q origin main 2>/dev/null; then
            if git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
                :
            elif git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
                [ "$DRY" = 0 ] || die "yerel main origin/main'in gerisinde (önce: git pull --ff-only)"
                git merge -q --ff-only origin/main || die "git pull --ff-only başarısız"
            else
                die "yerel main ile origin/main ayrışmış; elle çözün (force push yok)"
            fi
        else
            [ -z "$(git ls-remote --heads origin main 2>/dev/null || echo FAIL)" ] || die "git fetch origin main başarısız (ağ?)"
            echo "bilgi: origin'de main henüz yok (ilk yayın); ff-only denetimi atlandı"
        fi
    else
        echo "bilgi: origin tanımlı değil; ff-only denetimi atlandı"
    fi
}

# KEY ve PUB değişkenlerini ayarlar. $1 = pub (yalnız .pub gerekir) | priv (özel anahtar dosyası da gerekir)
resolve_key() {
    KEY="${INDEX_SIGNING_KEY:-${PAKET_SIGNING_KEY:-}}"
    [ -n "$KEY" ] || die "INDEX_SIGNING_KEY (ya da PAKET_SIGNING_KEY) ayarlı değil"
    PUB="$KEY.pub"
    [ -f "$PUB" ] || die "açık anahtar yok: $PUB"
    if [ "$1" = priv ]; then [ -f "$KEY" ] || die "özel anahtar dosyası yok: $KEY"; fi
    PUBLINE=$(head -n1 "$PUB")
    PUBTYPE=$(printf '%s' "$PUBLINE" | cut -d' ' -f1)
    PUBB64=$(printf '%s' "$PUBLINE" | cut -d' ' -f2)
    [[ "$PUBTYPE" == ssh-* ]] && [ -n "$PUBB64" ] || die "$PUB geçerli bir açık anahtar satırı değil"
}

# ---- add ----
do_add() {
    [ "${#POS[@]}" -eq 4 ] || die "kullanım: add <id> <sürüm> <sahip/depo> [seçenekler]"
    local id="${POS[1]}" ver="${POS[2]}" repo="${POS[3]}" asset cur pcur have
    [[ "$id" =~ ^[a-z][a-z0-9-]{0,63}$ ]] || die "paket kimliği geçersiz: '$id'"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "sürüm X.Y.Z olmalı: '$ver'"
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && [ "${repo%%/*}" != "." ] && [ "${repo%%/*}" != ".." ] && [ "${repo##*/}" != "." ] && [ "${repo##*/}" != ".." ] || die "depo sahip/depo biçiminde olmalı: '$repo'"
    asset="$id-$ver.tar.gz"
    preflight_repo
    resolve_key pub

    # geri sürüm yok / aynı sürüm yeniden yazılmaz (indeks ve taslak)
    cur=$(lib field index.json "$id" version 2>/dev/null || true)
    pcur=""; [ ! -f "$PENDING" ] || pcur=$(lib field "$PENDING" "$id" version)
    ADD_STATE=added
    for have in "$cur" "$pcur"; do
        [ -n "$have" ] || continue
        if lib newer "$have" "$ver"; then die "$id $ver, mevcut $have sürümünden küçük (geri sürüm yok)"; fi
    done
    for have in "$cur" "$pcur"; do
        if [ -n "$have" ] && [ "$have" = "$ver" ]; then ADD_STATE=same; fi
    done

    local a s
    if [ -n "$ARCHIVE" ]; then
        [ -f "$ARCHIVE" ] && [ -f "$SIG" ] || die "arşiv ya da imza dosyası yok: $ARCHIVE / $SIG"
        a="$ARCHIVE"; s="$SIG"
    else
        [ "$ADD_STATE" = same ] || command -v curl >/dev/null || die "curl yok (GitHub'dan indirmek için)"
        if [ "$ADD_STATE" != same ]; then
            a="$WORK/$asset"; s="$WORK/$asset.sig"
            local base="https://github.com/$repo/releases/download/v$ver"
            echo "indiriliyor: $base/$asset"
            curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 120 --max-filesize 52428800 -o "$a" "$base/$asset" || die "arşiv indirilemedi"
            curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 60 --max-filesize 4096 -o "$s" "$base/$asset.sig" || die "imza indirilemedi"
        fi
    fi

    if [ "$ADD_STATE" = same ]; then
        # aynı sürüm zaten yazılı: yerel arşiv verildiyse özet çelişkisini yine de yakala
        if [ -n "$ARCHIVE" ]; then
            local ex
            ex=$(lib field index.json "$id" sha256 2>/dev/null || true)
            [ -n "$ex" ] || ex=$(lib field "$PENDING" "$id" sha256)
            [ "$(sha_of "$a")" = "$ex" ] || die "$id $ver zaten yazılı ama özet farklı (aynı sürüm yeniden yazılamaz)"
        fi
        echo "$id $ver zaten güncel (indekste/taslakta var)."
        return 0
    fi

    # bağımsız doğrulama: paket imzası (ad alanı sshpocket-component, imzacı = .pub)
    printf '%s namespaces="%s" %s %s\n' "$PKG_NS" "$PKG_NS" "$PUBTYPE" "$PUBB64" > "$WORK/pkg_signers"
    ssh-keygen -Y verify -f "$WORK/pkg_signers" -I "$PKG_NS" -n "$PKG_NS" -s "$s" < "$a" >/dev/null 2>&1 \
        || die "paket imzası geçersiz ($PUB ile, ad alanı $PKG_NS)"
    echo "paket imzası: geçerli"

    tar -tzf "$a" >"$WORK/list" 2>/dev/null || die "arşiv okunamadı (tar.gz değil?)"
    if grep -qv "^$id-$ver/" "$WORK/list"; then die "arşivde $id-$ver/ dışında yol var"; fi
    local cj got
    cj=$(tar -xzOf "$a" "$id-$ver/component.json" 2>/dev/null) || die "arşivde $id-$ver/component.json yok"
    got=$(printf '%s' "$cj" | lib cjson) || die "component.json okunamadı"
    [ "$got" = "$id $ver" ] || die "component.json uyuşmuyor: '$got' (beklenen '$id $ver')"
    echo "component.json: id/sürüm eşleşiyor"

    local sha
    sha=$(sha_of "$a")
    # GitHub'daki asset digest'i (gh varsa) yerel özetle aynı mı
    if command -v gh >/dev/null 2>&1; then
        local dig
        if dig=$(gh api "repos/$repo/releases/tags/v$ver" --jq ".assets[] | select(.name==\"$asset\") | .digest" 2>/dev/null); then
            if [ -z "$dig" ]; then die "GitHub Release v$ver içinde $asset asset'i yok"
            elif [ "$dig" = "null" ]; then echo "uyarı: GitHub bu asset için digest vermiyor; karşılaştırma atlandı" >&2
            else [ "$dig" = "sha256:$sha" ] || die "GitHub digest ($dig) ile yerel sha256 ($sha) çelişiyor"
                echo "GitHub digest: yerel özetle aynı"; fi
        else
            echo "uyarı: gh api başarısız; GitHub digest karşılaştırması atlandı" >&2
        fi
    else
        echo "uyarı: gh yok; GitHub digest karşılaştırması atlandı" >&2
    fi

    local plat="$PLATFORMS"
    [ -n "$plat" ] || plat=$(printf '%s' "$cj" | lib profiles)
    echo "eklenecek: $id $ver ($repo) sha256=$sha${REQUIRES:+ requires_sshpocket=$REQUIRES}${plat:+ platforms=$plat}"
    if [ "$DRY" = 1 ]; then say_dry "taslağa yazılmadı."; return 0; fi
    lib pending-add "$PENDING" "$id" "$repo" "$ver" "$sha" "$REQUIRES" "$plat"
    echo "taslağa eklendi: $PENDING"
}

# ---- sign / refresh ----
# $1 = sign | refresh
do_sign() {
    local mode="$1" pend="-" st="$WORK/stage" prev changed msg agentpub keyarg cnt
    preflight_repo
    if [ "$mode" = sign ]; then
        [ -f "$PENDING" ] || die "taslak yok ($PENDING); önce: add <id> <sürüm> <sahip/depo>"
        pend="$PENDING"
    else
        [ ! -f "$PENDING" ] || die "bekleyen taslak var; yenilemeden önce sign ile imzalayın (ya da $PENDING silin)"
        [ -f index.json ] && [ -f index.json.sig ] || die "refresh için mevcut index.json ve index.json.sig gerekir"
    fi
    resolve_key priv
    grep -v '^[[:space:]]*#' index_signers | grep -qF "$PUBB64" || die "$PUB, index_signers içinde yok; bu anahtarla imzalanan indeks istemcide geçmez"

    mkdir -p "$st"
    prev=$(lib serial index.json) || die "mevcut index.json okunamadı"
    changed=$(lib merge index.json "$pend" "$st/index.json" "$DAYS") || die "birleştirme başarısız"
    lib validate "$st/index.json" "$prev" || die "üretilen indeks biçim denetiminden geçmedi"
    cnt=$((prev + 1))
    if [ "$mode" = sign ]; then msg="indeks: $(printf '%s' "$changed" | paste -sd, - | sed 's/,/, /g') (seri $cnt)"; else msg="indeks: yenile (seri $cnt)"; fi
    echo "$msg  [geçerlilik: $DAYS gün]"
    if [ "$DRY" = 1 ]; then
        say_dry "imzalanmadı, dosya/commit yazılmadı. Yapılacak: $msg"
        return 0
    fi
    confirm "İmzalansın ve yerel commit atılsın mı? (parola istemi ssh-keygen'den gelir)"

    keyarg="$KEY"
    if [ -n "${SSH_AUTH_SOCK:-}" ] && command -v ssh-add >/dev/null 2>&1; then
        agentpub=$(ssh-add -L 2>/dev/null || true)
        if printf '%s\n' "$agentpub" | grep -qF "$PUBB64"; then keyarg="$PUB"; echo "anahtar ssh-agent'ta: parola sorulmayacak"; fi
    fi
    ssh-keygen -Y sign -f "$keyarg" -n "$INDEX_NS" "$st/index.json" || die "imzalama başarısız"
    [ -s "$st/index.json.sig" ] || die "imza dosyası üretilmedi"

    # kendi doğrulaması: depodaki index_signers ile, sonra biçim + seri
    ssh-keygen -Y verify -f index_signers -I "$INDEX_NS" -n "$INDEX_NS" -s "$st/index.json.sig" < "$st/index.json" >/dev/null 2>&1 \
        || die "kendi doğrulaması başarısız: imza index_signers ile doğrulanmıyor (hiçbir dosya yazılmadı)"
    [ "$(wc -c < "$st/index.json.sig")" -le 4096 ] || die "imza 4 KiB sınırını aşıyor"
    lib validate "$st/index.json" "$prev" || die "kendi doğrulaması: biçim/seri hatası (hiçbir dosya yazılmadı)"
    echo "kendi doğrulaması: imza, biçim ve seri artışı geçerli (seri $cnt)"

    # yaz + commit; commit başarısızsa eski hâle dön
    local had=0
    if [ -f index.json ]; then had=1; cp index.json "$WORK/old.json"; cp index.json.sig "$WORK/old.sig"; fi
    cp "$st/index.json" index.json.new && mv index.json.new index.json
    cp "$st/index.json.sig" index.json.sig.new && mv index.json.sig.new index.json.sig
    if ! { git add index.json index.json.sig && git commit -q -m "$msg"; }; then
        if [ "$had" = 1 ]; then cp "$WORK/old.json" index.json; cp "$WORK/old.sig" index.json.sig; git reset -q index.json index.json.sig || true
        else rm -f index.json index.json.sig; git rm -q --cached -f index.json index.json.sig 2>/dev/null || true; fi
        die "git commit başarısız; dosyalar eski hâline döndürüldü"
    fi
    rm -f "$PENDING"
    echo "yerel commit atıldı: $msg"
    echo "Push (sizde):  git -C \"$REPO_DIR\" push origin main"
}

case "${POS[0]}" in
    add) do_add ;;
    sign) [ "${#POS[@]}" -eq 1 ] || die "sign argüman almaz"; do_sign sign ;;
    refresh) [ "${#POS[@]}" -eq 1 ] || die "refresh argüman almaz"; do_sign refresh ;;
    *)
        [ "${#POS[@]}" -eq 3 ] || die "bilinmeyen komut '${POS[0]}' (add | sign | refresh | <id> <sürüm> <sahip/depo>)"
        POS=(add "${POS[0]}" "${POS[1]}" "${POS[2]}")
        ADD_STATE=""
        do_add
        if [ "$ADD_STATE" = same ] && [ ! -f "$PENDING" ]; then exit 0; fi
        if [ "$DRY" = 1 ]; then say_dry "sonra sign çalışırdı (taslak dry-run'da yazılmadığı için burada gösterilmez)."; exit 0; fi
        do_sign sign
        ;;
esac
