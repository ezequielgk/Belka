# moss

Gestor de paquetes y tarballs (`.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar.zst`) estrictamente **Headless y CLI** escrito en **POSIX sh puro**. 
Diseñado con una filosofía similar a `brew` o `nix`, aislando las instalaciones y generando symlinks inteligentes. Sin bashismos: corre nativamente bajo `dash` y `busybox ash`, lo que lo hace perfecto para CI/CD y scripts de automatización.

## Dependencias

Obligatorias: `tar`, `find`, `sort`, `awk`, `sed`, `grep`, `date`, `cp`, `sha256sum` (o `shasum -a 256`, u `openssl`), `curl` **o** `wget`, `jq` (para compilar el índice).
Opcionales: `gpg` (verificación de firmas), `mktemp` (hay fallback POSIX).

## Arquitectura de Instalación y Sandboxing

A diferencia de gestores tradicionales que mezclan miles de archivos, `moss` emplea una estrategia de aislamiento estricto:

- **MOSS_PREFIX**: Por defecto se instala en `~/.local/moss` (usuario) o `/usr/local/moss` (con flag `--system`).
- **Paquetes Normales**: Se aíslan en la subcarpeta `pkg/<nombre_paquete>/`.
- **Paquetes Masivos (>100 archivos)**: Se aíslan en la subcarpeta `opt/<nombre_paquete>/` para evitar cuellos de botella.
- **Symlinks Inteligentes**: Sin importar el tamaño, el binario ejecutable se expone limpia y automáticamente mediante un enlace simbólico en `bin/`. 

*Nota:* Asegúrate de agregar el path a tu terminal: `export PATH="$HOME/.local/moss/bin:$PATH"`

## Uso Rápido

```sh
moss update                                 # Sincronizar/actualizar el índice remoto
moss install foo                            # Instalar paquete por nombre desde el índice
moss install ./foo-1.0.0.tar.gz             # Instalar archivo local directamente
moss update foo ./foo-2.0.0.tar.gz          # Actualización de paquete forzada vía archivo local
moss list                                   # Listar paquetes instalados
moss search foo                             # Buscar en el índice
moss info foo                               # Mostrar información de estado
moss verify foo                             # Verificar checksums del tarball local
moss rollback foo                           # Volver a la versión previa del paquete
moss remove foo                             # Desinstalar un paquete
```

## Ecosistema de Datos y GitHub Actions

El repositorio de `moss` sigue un paradigma impulsado por datos (Data-Driven):

1. **`meta/apps.list`**: La fuente de la verdad. Un simple listado TSV (Nombre, Repo, Patrón, Descripción).
2. **`scripts/build-repo.sh`**: Script que consulta la API de GitHub Releases, extrae URLs de descarga dinámicas y precalcula los SHA256.
3. **`.github/workflows/update.yml`**: Bot automático que corre todos los días a las 03:00 AM UTC. Si detecta nuevas versiones, re-construye silenciosamente el `packages.tsv` y hace `push` al índice.

## Estado y Seguridad

Por paquete en `$MOSS_STATE_DIR/<nombre>/` (ej: `~/.local/share/moss/`): `manifest` (KEY=VALUE: name, version, url, sha256, prefix, tarball, installed_at), `files` (rutas instaladas), y `manifest.bak`/`files.bak` para `rollback`.

Pipeline: descarga a caché -> verificación sha256 -> extracción a staging temporal -> aislamiento en `pkg/` u `opt/` -> creación de Symlink -> copia con **rollback automático** si falla a mitad. 

## Códigos de Salida (Automatización)

`0` ok · `1` uso/no encontrado · `2` descarga (incluye índice sin caché) ·
`3` verificación · `4` instalación · `5` conflicto · `6` dependencia faltante.

## Estructura del Repositorio

```text
bin/moss                     # CLI de Moss (POSIX sh)
meta/apps.list               # Semilla del repositorio de GitHub (TSV)
scripts/build-repo.sh        # Generador del índice desde GitHub Releases
index/packages.tsv           # Índice compilado automáticamente por el Bot
.github/workflows/update.yml # CI/CD diario de automatización
tests/run_tests.sh           # Batería de pruebas unitarias
README.md                    # Este archivo
```
