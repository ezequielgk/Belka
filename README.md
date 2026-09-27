# moss

Gestor de tarballs (`.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar.zst`) escrito en
**POSIX sh estricto**. Modo CLI completo + TUI con `fzf` (fallback a menu
numerado). Sin bashismos: corre bajo `dash` y `busybox ash`.

## Dependencias

Obligatorias: `tar`, `find`, `sort`, `awk`, `sed`, `grep`, `date`, `cp`,
`sha256sum` (o `shasum -a 256`, u `openssl`), `curl` **o** `wget`.
Opcionales: `fzf` (TUI), `gpg` (firmas), `mktemp` (hay fallback POSIX).

## Uso rapido

```sh
moss sync                                   # descargar/actualizar el indice
moss install foo                            # instalar (nombre del indice)
moss install ./foo-1.0.0.tar.gz             # archivo local
moss install https://example.org/foo.tar.gz # URL directa
moss list / search / info / verify foo
moss update foo | moss update --all
moss rollback foo
moss remove foo
moss                                        # TUI (fzf o menu de texto)
```

## Sistema de indice

- Fuente: `MOSS_INDEX_URL` (default `https://raw.githubusercontent.com/<user>/moss/main/index/packages.tsv`),
  `--index`, o `~/.config/moss/config`.
- Resolucion de fuente en `install`: **1)** ruta local existente,
  **2)** URL `http(s)://` o `file://` directa, **3)** nombre buscado en el indice
  (desde ahi salen url, sha256 y firma).
- El indice se cachea en `~/.cache/moss/index/packages.tsv` con TTL de
  `MOSS_INDEX_TTL` horas (default 24; `0` = refrescar siempre). `moss sync`
  fuerza la re-descarga. `--offline` usa el cache aunque este vencido.
- Formato TSV: `nombre TAB version TAB url TAB sha256 TAB descripcion [TAB firma.asc]`.
- Los tarballs **no se commitean**: se publican como assets de GitHub Releases
  y el indice apunta a ellos. Ver `index/packages.tsv`.

## Configuracion

`~/.config/moss/config` (`KEY=VALUE`, `#` comentarios):

```
MOSS_PREFIX=/opt/apps
MOSS_STATE_DIR=/opt/apps/.moss-state
MOSS_CACHE_DIR=/home/usuario/.cache/moss
MOSS_INDEX_URL=https://raw.githubusercontent.com/<user>/moss/main/index/packages.tsv
MOSS_INDEX_TTL=24
```

Precedencia: CLI > entorno > config > defectos (`~/.local`,
`~/.local/share/moss`, `${XDG_CACHE_HOME:-~/.cache}/moss`).

## Estado y seguridad

Por paquete en `$MOSS_STATE_DIR/<nombre>/`: `manifest` (KEY=VALUE: name,
version, url, sha256, prefix, tarball, installed_at), `files` (rutas
instaladas), y `manifest.bak`/`files.bak` para `rollback` despues de `update`.

Pipeline: descarga a cache (`<sha256>-<archivo>`) -> verificacion sha256 (y
firma GPG si hay `gpg`) -> extraccion a staging temporal (`mktemp` + `trap`) ->
deteccion de conflictos (con `--force` para sobrescribir) -> copia con
**rollback automatico** si falla a mitad. `update` respalda el manifest
anterior y revierte automaticamente si la actualizacion falla.

Convencion de tarball: estructura de destino en la raiz (`bin/`, `share/`, ...);
carpeta raiz unica normalizada automaticamente. Limitacion: los directorios
vacios no se registran en `files`.

## Codigos de salida

`0` ok · `1` uso/no encontrado · `2` descarga (incluye indice sin cache) ·
`3` verificacion · `4` instalacion · `5` conflicto · `6` dependencia faltante.

## Tests

```sh
sh tests/run_tests.sh     # 17 grupos: install, checksum, conflicto, rollback,
                          # remove, update(+resumen), verify, dry-run,
                          # list/search/info(JSON), fallback TUI, resolucion
                          # de fuente, sync, TTL y offline
```

## Estructura

```
bin/moss                 # script principal (POSIX sh)
index/packages.tsv       # indice del repo (TSV)
tests/run_tests.sh
examples/make_demo_repo.sh
README.md
```
