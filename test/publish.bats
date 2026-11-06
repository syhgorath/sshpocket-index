#!/usr/bin/env bats
load helper

setup() { setup_repo; }
teardown() { teardown_repo; }

@test "ilk yayın: add + sign -> seri 1, imza geçerli, yerel commit, tek satır push, taslak silinir, push yok" {
    mkpkg utility 0.1.1
    run padd utility 0.1.1
    [ "$status" -eq 0 ]
    [ -f "$R/index.pending.json" ]
    [ ! -e "$R/index.json" ]
    run "$PUBLISH" sign --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"git -C"*"push origin main"* ]]
    [ "$(jget "$R/index.json" serial)" = 1 ]
    [ "$(jget "$R/index.json" schema)" = 1 ]
    [ "$(jget "$R/index.json" packages utility version)" = 0.1.1 ]
    [ "$(jget "$R/index.json" packages utility asset)" = utility-0.1.1.tar.gz ]
    [ "$(jget "$R/index.json" packages utility sha256)" = "$(shasum -a 256 "$T/arch/utility-0.1.1.tar.gz" | cut -d' ' -f1)" ]
    [ "$(jget "$R/index.json" packages utility platforms)" = "['ubuntu-26.04']" ]
    [ ! -e "$R/index.pending.json" ]
    [ "$(git -C "$R" log -1 --format=%s)" = "indeks: utility 0.1.1 (seri 1)" ]
    [ -z "$(git -C "$R" status --porcelain)" ]
    run ssh-keygen -Y verify -f "$R/index_signers" -I sshpocket-index -n sshpocket-index -s "$R/index.json.sig" < "$R/index.json"
    [ "$status" -eq 0 ]
}

@test "indeks imzası yalnız sshpocket-index ad alanında geçer" {
    mkpkg utility 0.1.1
    padd utility 0.1.1
    "$PUBLISH" sign --yes
    run ssh-keygen -Y verify -f "$R/index_signers" -I sshpocket-index -n sshpocket-component -s "$R/index.json.sig" < "$R/index.json"
    [ "$status" -ne 0 ]
}

@test "belirlenimli üretim: index.json kanonik biçimde (sort_keys, indent 2, ensure_ascii, son satır LF)" {
    mkpkg utility 0.1.1
    padd utility 0.1.1 --requires-sshpocket 3.7.0 --platforms ubuntu-26.04,debian-13
    "$PUBLISH" sign --yes
    run python3 -I -c 'import json,sys
raw=open(sys.argv[1],"rb").read()
exp=(json.dumps(json.loads(raw),sort_keys=True,indent=2,ensure_ascii=True)+"\n").encode()
sys.exit(0 if raw==exp else 1)' "$R/index.json"
    [ "$status" -eq 0 ]
}

@test "seri artışı: ikinci sign seri 2 ve iki paket" {
    mkpkg utility 0.1.1; mkpkg kurulum 0.1.0
    padd utility 0.1.1; "$PUBLISH" sign --yes
    padd kurulum 0.1.0; "$PUBLISH" sign --yes
    [ "$(jget "$R/index.json" serial)" = 2 ]
    [ "$(jget "$R/index.json" packages utility version)" = 0.1.1 ]
    [ "$(jget "$R/index.json" packages kurulum version)" = 0.1.0 ]
    [ "$(git -C "$R" log -1 --format=%s)" = "indeks: kurulum 0.1.0 (seri 2)" ]
}

@test "birden çok add + tek sign: seri 1 ve ileti iki paketi sayar" {
    mkpkg utility 0.1.1; mkpkg kurulum 0.1.0
    padd utility 0.1.1; padd kurulum 0.1.0
    "$PUBLISH" sign --yes
    [ "$(jget "$R/index.json" serial)" = 1 ]
    [ "$(git -C "$R" log -1 --format=%s)" = "indeks: kurulum 0.1.0, utility 0.1.1 (seri 1)" ]
}

@test "tek komut biçimi: <id> <sürüm> <depo> = add + sign" {
    mkpkg utility 0.1.1
    run "$PUBLISH" utility 0.1.1 syhgorath/utility --archive "$T/arch/utility-0.1.1.tar.gz" --sig "$T/arch/utility-0.1.1.tar.gz.sig" --yes
    [ "$status" -eq 0 ]
    [ "$(jget "$R/index.json" serial)" = 1 ]
}

@test "aynı sürüm tekrarı: 'zaten güncel', çıkış 0, seri/commit değişmez" {
    mkpkg utility 0.1.1
    padd utility 0.1.1; "$PUBLISH" sign --yes
    local head; head=$(git -C "$R" rev-parse HEAD)
    run "$PUBLISH" utility 0.1.1 syhgorath/utility --archive "$T/arch/utility-0.1.1.tar.gz" --sig "$T/arch/utility-0.1.1.tar.gz.sig" --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"zaten güncel"* ]]
    [ "$(git -C "$R" rev-parse HEAD)" = "$head" ]
    [ "$(jget "$R/index.json" serial)" = 1 ]
    [ ! -e "$R/index.pending.json" ]
}

@test "aynı sürüm ama farklı arşiv özeti reddedilir" {
    mkpkg utility 0.1.1
    padd utility 0.1.1; "$PUBLISH" sign --yes
    echo extra > "$T/src/utility-0.1.1/EKSTRA"
    tar -czf "$T/arch/utility-0.1.1.tar.gz" -C "$T/src" utility-0.1.1
    rm "$T/arch/utility-0.1.1.tar.gz.sig"
    ssh-keygen -q -Y sign -f "$T/key" -n sshpocket-component "$T/arch/utility-0.1.1.tar.gz"
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"özet farklı"* ]]
}

@test "küçük (ve eşit olmayan eski) sürüm reddedilir" {
    mkpkg utility 0.1.1; mkpkg utility 0.1.0
    padd utility 0.1.1; "$PUBLISH" sign --yes
    run padd utility 0.1.0
    [ "$status" -ne 0 ]
    [[ "$output" == *"geri sürüm yok"* ]]
    [ ! -e "$R/index.pending.json" ]
}

@test "taslaktaki sürümden küçük sürüm de reddedilir; büyüğü taslağı değiştirir" {
    mkpkg utility 0.1.1; mkpkg utility 0.1.0; mkpkg utility 0.1.2
    padd utility 0.1.1
    run padd utility 0.1.0
    [ "$status" -ne 0 ]
    padd utility 0.1.2
    [ "$(jget "$R/index.pending.json" packages utility version)" = 0.1.2 ]
}

@test "bozuk paket imzası reddedilir (başka anahtarla imzalı)" {
    mkpkg utility 0.1.1 "$T/other"
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"paket imzası geçersiz"* ]]
    [ ! -e "$R/index.pending.json" ]
}

@test "yanlış ad alanlı paket imzası reddedilir" {
    mkpkg utility 0.1.1 "$T/key" sshpocket-index
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"paket imzası geçersiz"* ]]
}

@test "arşiv değişmiş (imza eski arşive ait) reddedilir" {
    mkpkg utility 0.1.1
    cp "$T/arch/utility-0.1.1.tar.gz.sig" "$T/saved.sig"
    echo x >> "$T/src/utility-0.1.1/VERSION"
    tar -czf "$T/arch/utility-0.1.1.tar.gz" -C "$T/src" utility-0.1.1
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"paket imzası geçersiz"* ]]
}

@test "component.json id uyuşmazlığı reddedilir" {
    mkpkg_cj utility 0.1.1 '{"id":"baska","version":"0.1.1"}'
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"component.json uyuşmuyor"* ]]
}

@test "component.json sürüm uyuşmazlığı reddedilir" {
    mkpkg_cj utility 0.1.1 '{"id":"utility","version":"0.1.0"}'
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"component.json uyuşmuyor"* ]]
}

@test "GitHub digest yerel sha256 ile çelişirse reddedilir" {
    mkpkg utility 0.1.1
    export GH_DIGEST="sha256:$(printf '0%.0s' $(seq 1 64))"
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"çelişiyor"* ]]
    [ ! -e "$R/index.pending.json" ]
}

@test "GitHub digest yerel sha256 ile aynıysa kabul edilir" {
    mkpkg utility 0.1.1
    export GH_DIGEST="sha256:$(shasum -a 256 "$T/arch/utility-0.1.1.tar.gz" | cut -d' ' -f1)"
    run padd utility 0.1.1
    [ "$status" -eq 0 ]
    [[ "$output" == *"GitHub digest: yerel özetle aynı"* ]]
    [ -f "$R/index.pending.json" ]
}

@test "add --dry-run hiçbir şey yazmaz" {
    mkpkg utility 0.1.1
    local before; before=$(snapshot)
    run padd utility 0.1.1 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run]"* ]]
    [ "$(snapshot)" = "$before" ]
    [ ! -e "$R/index.pending.json" ]
}

@test "sign --dry-run hiçbir şey yazmaz, anahtarı kullanmaz" {
    mkpkg utility 0.1.1
    padd utility 0.1.1
    local before; before=$(snapshot)
    run "$PUBLISH" sign --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"seri 1"* ]]
    [ "$(snapshot)" = "$before" ]
    [ ! -e "$R/index.json" ]
}

@test "tek komut --dry-run hiçbir şey yazmaz" {
    mkpkg utility 0.1.1
    local before; before=$(snapshot)
    run "$PUBLISH" utility 0.1.1 syhgorath/utility --archive "$T/arch/utility-0.1.1.tar.gz" --sig "$T/arch/utility-0.1.1.tar.gz.sig" --dry-run
    [ "$status" -eq 0 ]
    [ "$(snapshot)" = "$before" ]
}

@test "refresh: içerik aynı, seri+1, valid_until ileri; refresh --dry-run yazmaz" {
    mkpkg utility 0.1.1
    padd utility 0.1.1; "$PUBLISH" sign --yes --valid-days 10
    local v1; v1=$(jget "$R/index.json" valid_until)
    local before; before=$(snapshot)
    run "$PUBLISH" refresh --dry-run
    [ "$status" -eq 0 ]
    [ "$(snapshot)" = "$before" ]
    sleep 1
    run "$PUBLISH" refresh --yes
    [ "$status" -eq 0 ]
    [ "$(jget "$R/index.json" serial)" = 2 ]
    [ "$(jget "$R/index.json" packages utility version)" = 0.1.1 ]
    [[ "$(jget "$R/index.json" valid_until)" > "$v1" ]]
    [ "$(git -C "$R" log -1 --format=%s)" = "indeks: yenile (seri 2)" ]
    run ssh-keygen -Y verify -f "$R/index_signers" -I sshpocket-index -n sshpocket-index -s "$R/index.json.sig" < "$R/index.json"
    [ "$status" -eq 0 ]
}

@test "refresh: indeks yoksa ve taslak varsa reddedilir" {
    run "$PUBLISH" refresh --yes
    [ "$status" -ne 0 ]
    mkpkg utility 0.1.1; padd utility 0.1.1; "$PUBLISH" sign --yes
    mkpkg utility 0.1.2; padd utility 0.1.2
    run "$PUBLISH" refresh --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"bekleyen taslak"* ]]
}

@test "valid_until = issued_at + --valid-days; 90 günden büyük reddedilir" {
    mkpkg utility 0.1.1
    padd utility 0.1.1
    run "$PUBLISH" sign --yes --valid-days 91
    [ "$status" -ne 0 ]
    "$PUBLISH" sign --yes --valid-days 30
    run python3 -I -c 'import json,sys,datetime as d
j=json.load(open(sys.argv[1])); f="%Y-%m-%dT%H:%M:%SZ"
sys.exit(0 if d.datetime.strptime(j["valid_until"],f)-d.datetime.strptime(j["issued_at"],f)==d.timedelta(days=30) else 1)' "$R/index.json"
    [ "$status" -eq 0 ]
}

@test "sign: taslak yoksa hata" {
    run "$PUBLISH" sign --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"taslak yok"* ]]
}

@test "sign: anahtar index_signers'ta yoksa imzalamadan önce reddedilir" {
    mkpkg utility 0.1.1
    padd utility 0.1.1
    INDEX_SIGNING_KEY="$T/other" run "$PUBLISH" sign --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"index_signers içinde yok"* ]]
    [ ! -e "$R/index.json" ]
    [ -f "$R/index.pending.json" ]
}

@test "anahtar: yoksa hata; .pub yoksa hata; PAKET_SIGNING_KEY yedeği çalışır" {
    mkpkg utility 0.1.1
    INDEX_SIGNING_KEY="" run padd utility 0.1.1
    [ "$status" -ne 0 ]
    INDEX_SIGNING_KEY="$T/yok" run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"açık anahtar yok"* ]]
    unset INDEX_SIGNING_KEY
    PAKET_SIGNING_KEY="$T/key" run padd utility 0.1.1
    [ "$status" -eq 0 ]
}

@test "kendi doğrulaması: imza üretilemezse (sahte ssh-keygen) dosya yazılmaz, commit yok" {
    mkpkg utility 0.1.1
    padd utility 0.1.1
    cat > "$T/bin/ssh-keygen" <<'SK'
#!/bin/sh
# -Y sign çağrısını bozuk imzayla taklit et; diğerlerini gerçeğe ilet
case "$*" in
  *"-Y sign"*) for last; do :; done; printf 'bozuk' > "$last.sig"; exit 0 ;;
esac
exec /usr/bin/ssh-keygen "$@"
SK
    chmod +x "$T/bin/ssh-keygen"
    [ -x /usr/bin/ssh-keygen ] || skip "/usr/bin/ssh-keygen yok"
    run "$PUBLISH" sign --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"kendi doğrulaması başarısız"* ]]
    [ ! -e "$R/index.json" ]
    [ "$(git -C "$R" log -1 --format=%s)" = "init" ]
    [ -f "$R/index.pending.json" ]
}

@test "depo temiz değilse ya da main'de değilse reddedilir" {
    mkpkg utility 0.1.1
    echo x > "$R/kirli.txt"
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"temiz değil"* ]]
    rm "$R/kirli.txt"
    git -C "$R" checkout -q -b baska
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"main dalında"* ]]
}

@test "origin ilerideyse ff-only ile alınır; ayrışmışsa reddedilir" {
    mkpkg utility 0.1.1
    git init -q --bare -b main "$T/origin.git"
    git -C "$R" remote add origin "$T/origin.git"
    git -C "$R" push -q origin main
    git clone -q "$T/origin.git" "$T/other_clone"
    git -C "$T/other_clone" config user.email t@example.com; git -C "$T/other_clone" config user.name t
    echo n > "$T/other_clone/NOT"; git -C "$T/other_clone" add NOT; git -C "$T/other_clone" commit -q -m not; git -C "$T/other_clone" push -q origin main
    run padd utility 0.1.1
    [ "$status" -eq 0 ]
    [ -f "$R/NOT" ]
    # ayrışma
    echo y > "$R/YEREL"; git -C "$R" add YEREL; git -C "$R" commit -q -m yerel
    echo z > "$T/other_clone/NOT2"; git -C "$T/other_clone" add NOT2; git -C "$T/other_clone" commit -q -m not2; git -C "$T/other_clone" push -q origin main
    run padd utility 0.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"ayrışmış"* ]]
}

@test "yalnız --archive verilirse hata; bilinmeyen seçenek/komut hata" {
    run "$PUBLISH" add utility 0.1.1 syhgorath/utility --archive "$T/x"
    [ "$status" -ne 0 ]
    run "$PUBLISH" --yok
    [ "$status" -ne 0 ]
    run "$PUBLISH" bilinmeyen
    [ "$status" -ne 0 ]
}

@test "geçersiz id/sürüm/depo reddedilir" {
    mkpkg utility 0.1.1
    run "$PUBLISH" add Utility 0.1.1 syhgorath/utility --archive "$T/arch/utility-0.1.1.tar.gz" --sig "$T/arch/utility-0.1.1.tar.gz.sig"
    [ "$status" -ne 0 ]
    run "$PUBLISH" add utility 0.1 syhgorath/utility --archive "$T/arch/utility-0.1.1.tar.gz" --sig "$T/arch/utility-0.1.1.tar.gz.sig"
    [ "$status" -ne 0 ]
    run "$PUBLISH" add utility 0.1.1 ../utility --archive "$T/arch/utility-0.1.1.tar.gz" --sig "$T/arch/utility-0.1.1.tar.gz.sig"
    [ "$status" -ne 0 ]
}

@test "betik gerçek anahtar yoluna ve parolaya başvurmaz" {
    ! grep -q "sshpocket_release" "$ROOT/scripts/index-publish.sh"
    ! grep -qiE 'passphrase|SSH_ASKPASS|read -s' "$ROOT/scripts/index-publish.sh"
}

@test "bash 3.2 uyumu: ilişkisel dizi, mapfile, \${var,,} yok" {
    ! grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)' "$ROOT/scripts/index-publish.sh"
}

@test "paylaşılan index_signers yayın anahtarının satırını taşır" {
    run grep -c '^sshpocket-index namespaces="sshpocket-index" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKVJS3mGlCaOT/l8XfR0TxuKxqLUs6PpVDa9TYqm0fLn$' "$ROOT/index_signers"
    [ "$output" = 1 ]
}

@test "göreli --archive/--sig çağıranın dizinine göre çözülür" {
    mkpkg utility 0.1.1
    cd "$T/arch"
    run "$PUBLISH" add utility 0.1.1 syhgorath/utility --archive utility-0.1.1.tar.gz --sig utility-0.1.1.tar.gz.sig
    [ "$status" -eq 0 ]
    [ -f "$R/index.pending.json" ]
}
