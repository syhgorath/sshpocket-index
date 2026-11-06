# sshpocket-index

sshpocket bileşen paketlerinin **imzalı indeksi**. Her paketin güncel sürümünü ve arşiv özetini söyler; sshpocket (3.7.0+) `components update | upgrade | list` ile bunu okur. Böylece yeni bir paket sürümü için ayrıca `components.lock` PR'ı ve sshpocket sürümü gerekmez.

Biçim, doğrulama algoritması ve güvenlik ilkeleri: sshpocket deposundaki `docs/package-index.md` (şartname; bu depo onun **yayın** tarafıdır).

## Dosyalar

| Dosya | Anlamı |
|---|---|
| `index.json` | Paket başına güncel sürüm, `asset`, `sha256`, `serial`, `issued_at`, `valid_until` (belirlenimli JSON). |
| `index.json.sig` | `index.json` ham baytlarının ssh imzası, ad alanı `sshpocket-index`. |
| `index_signers` | Güvenilen açık anahtar (mevcut release anahtarı). sshpocket'teki `sistem/index_signers` ile **aynı** olmalı. |
| `scripts/index-publish.sh` | Bakımcı aracı: `add`, `sign`, `refresh`. |
| `scripts/index_lib.py` | Betiğin JSON/biçim yardımcısı (`python3 -I` ile çalışır). |
| `index.pending.json` | `add` ile biriken, **imzasız** taslak (`.gitignore`'da; commit edilmez). |

Özel anahtar bu depoya, CI'a ya da sohbete **konmaz**. Betik parolayı hiç okumaz; `ssh-keygen` kendisi sorar (anahtar `ssh-agent`'taysa sormaz).

## Yayın akışı

1. Paket deposunda `scripts/release-publish.sh` çalışır (etiket, paket + paket imzası, GitHub Release, özet doğrulaması) ve **sonunda** `index-publish.sh <id> <sürüm> <sahip/depo> --archive … --sig …` çağırır.
2. Betik: depo temiz/`main`/ff-only mi bakar → arşiv + `.sig`'i alır → paket imzasını anahtarın `.pub` dosyasıyla doğrular → `component.json` id/sürümünü ve GitHub asset digest'ini denetler → sürüm indeksteki sürümden büyük mü bakar (aynı sürüm zaten yazılıysa "zaten güncel", çıkış 0) → `sign`: serial+1, imza, **kendi doğrulaması** (`index_signers`), yerel commit.
3. **Push sizde:** betik sonunda tek satır push komutu yazdırır; `git push origin main` ile yayımlanır. Betik push/etiket/force push yapmaz.

İndeks en geç `valid_until` öncesi yenilenmelidir (`refresh`); yenilenmezse yalnız *yükseltme* durur, kurulu sistem etkilenmez.

## Komutlar

```bash
export INDEX_SIGNING_KEY=~/.ssh/sshpocket_release   # yoksa PAKET_SIGNING_KEY; yanında .pub şart

scripts/index-publish.sh <id> <sürüm> <sahip/depo> [seçenekler]        # add + sign
scripts/index-publish.sh add <id> <sürüm> <sahip/depo> [seçenekler]    # yalnız taslağa ekle (özel anahtar/parola gerekmez)
scripts/index-publish.sh sign                                          # taslağı birleştir, seri+1, imzala, commit
scripts/index-publish.sh refresh                                       # içerik aynı, seri+1, valid_until uzat, imzala, commit
```

Seçenekler: `--archive YOL --sig YOL` (yoksa Release'ten indirilir), `--requires-sshpocket X.Y.Z`, `--platforms a,b` (yoksa `component.json`'daki `supported` profiller), `--valid-days N` (1–90, varsayılan 60), `--yes` (onay sorma), `--dry-run` (hiçbir şey yazmaz). `yank` komutu sonraya bırakıldı.

## İlk indeks

Ziya'nın çalıştıracağı tam komut dizisi: [docs/ilk-indeks.md](docs/ilk-indeks.md) (utility 0.1.1, kurulum 0.1.0, linux-hardening 0.13.0 → tek `sign` → push).

## Geliştirme

```bash
shellcheck -x -s bash scripts/index-publish.sh
bats test
```

Testler geçici üretilmiş anahtar kullanır, ağa çıkmaz (`gh` sahtelenir) ve gerçek anahtara dokunmaz. Betik macOS bash 3.2 ile uyumlu yazılmıştır.

Lisans: MIT (bkz. `LICENSE`).
