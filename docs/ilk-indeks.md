# İlk indeksin üretimi (Ziya'nın çalıştıracağı adımlar)

Bu adımlar **gerçek release anahtarını** (parola gerektirir) kullanır; bu yüzden yalnızca Ziya çalıştırır. Şartname: sshpocket deposu `docs/package-index.md` §10.

Ön koşul: üç paketin Release'leri yayımlı (utility v0.1.1, kurulum v0.1.0, linux-hardening v0.13.0) ve `gh auth status` açık (GitHub asset digest karşılaştırması için; yoksa betik uyarıp atlar).

## 1. GitHub'da depoyu aç (bir kez)

`syhgorath/sshpocket-index` adıyla **public**, boş (README/LICENSE ekleme) bir depo açın. Sonra:

```bash
git -C ~/Developer/sshpocket-index remote add origin git@github.com:syhgorath/sshpocket-index.git
git -C ~/Developer/sshpocket-index push -u origin main
```

(Bu push betik dosyalarını gönderir; henüz `index.json` yoktur. İlk indeks aşağıda.)

## 2. Anahtarı hazırla

```bash
export INDEX_SIGNING_KEY=~/.ssh/sshpocket_release        # yanında sshpocket_release.pub olmalı
ssh-add ~/.ssh/sshpocket_release                          # isteğe bağlı: parolayı bir kez girersiniz, betik agent'ı kullanır
```

## 3. Paketleri taslağa ekle (özel anahtar/parola gerekmez; yalnız `.pub` okunur)

```bash
cd ~/Developer/sshpocket-index
scripts/index-publish.sh add utility 0.1.1 syhgorath/utility
scripts/index-publish.sh add kurulum 0.1.0 syhgorath/kurulum
scripts/index-publish.sh add linux-hardening 0.13.0 syhgorath/linux-hardening
```

Her `add` Release'ten arşiv + `.sig` indirir, paket imzasını doğrular, `component.json` id/sürümünü ve GitHub digest'ini denetler. Önce `--dry-run` ile deneyebilirsiniz (hiçbir şey yazmaz).

## 4. Tek imza (parola turu burada)

```bash
scripts/index-publish.sh sign
```

Beklenen: `serial: 1`, üç paket, "kendi doğrulaması: ... geçerli", yerel commit `indeks: kurulum 0.1.0, linux-hardening 0.13.0, utility 0.1.1 (seri 1)`.

## 5. Kontrol ve push

```bash
cat index.json
# kurulum ve linux-hardening sha256 değerleri sshpocket'teki components.lock ile birebir aynı olmalı
git push origin main
```

Push sonrası CI'ın (shellcheck + bats) yeşil olduğunu görün. İstemci (sshpocket 3.7.0) bu adresten okur:
`https://raw.githubusercontent.com/syhgorath/sshpocket-index/main/index.json` (+ `.sig`).
