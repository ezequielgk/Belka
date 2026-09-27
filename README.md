# moss

Gestor de paquetes y tarballs (`.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar.zst`) estrictamente **Headless y CLI** escrito en **POSIX sh puro**. 
Diseñado con una filosofía similar a `brew` o `nix`, aislando las instalaciones y generando symlinks inteligentes. Sin bashismos: corre nativamente bajo `dash` y `busybox ash`, lo que lo hace perfecto para CI/CD y scripts de automatización.

## Dependencias

Obligatorias: `tar`, `find`, `sort`, `awk`, `sed`, `grep`, `date`, `cp`, `sha256sum` (o `shasum -a 256`, u `openssl`), `curl` **o** `wget`, `jq` (para compilar el índice).
Opcionales: `gpg` (verificación de firmas), `mktemp` (hay fallback POSIX).

## Arquitectura de Instalación y Sandboxing

A diferencia de gestores tradicionales que mezclan miles de archivos, `moss` emplea una estrategia de aislamiento estricto e inteligencia automatizada:

- **MOSS_PREFIX**: Por defecto se instala en `~/.local/moss` (usuario) o `/usr/local/moss` (con flag `--system`).
- **Paquetes Normales**: Se aíslan en la subcarpeta `pkg/<nombre_paquete>/`.
- **Paquetes Masivos (>100 archivos)**: Se aíslan en la subcarpeta `opt/<nombre_paquete>/` para evitar cuellos de botella y "suciendad" en el sistema.
- **Heurística de Ejecutables**: Moss lee una quinta columna `exec` en su índice de paquetes para determinar qué binario debe ser el "principal". De no existir, aplica una heurística nativa que busca y auto-selecciona el binario correcto dentro del tarball. El comando `install` también soporta `-e <binario>` para sobrescribir esto.
- **Symlinks y Escritorio Automáticos**: 
  - Expone limpia y automáticamente el binario detectado mediante un enlace simbólico en `bin/`. 
  - Si se trata de un paquete, genera un archivo `.desktop` válido en `~/.local/share/applications` para que aparezca mágicamente en tu menú de aplicaciones, sin importar si es un tarball genérico de internet.
- **Progreso Limpio**: Olvídate del "agujero negro". Moss emplea barras de progreso en texto plano (`[######---] 60%`) para descargas y extracciones pesadas, reportando exactamente lo que hace sin ahogar la consola con miles de líneas.

*Nota:* Asegúrate de agregar el path a tu terminal: `export PATH="$HOME/.local/moss/bin:$PATH"`

## Uso Rápido

```sh
moss update                                 # Sincronizar/actualizar el índice remoto localmente
moss install foo                            # Instalar paquete por nombre desde el índice
moss install ./foo-1.0.0.tar.gz             # Instalar archivo local directamente (sin índice)
moss upgrade                                # Actualizar todos los paquetes instalados a su última versión
moss list                                   # Tabla limpia de instalados (ID, Binario Real, Versión, Fecha)
moss search foo                             # Buscar en el índice
moss info foo                               # Mostrar información de estado detallada
moss verify foo                             # Verificar checksums del tarball local
moss rollback foo                           # Volver a la versión previa instalada del paquete
moss remove foo                             # Desinstalar mediante su ID de paquete original
moss remove my-foo-bin                      # Desinstalar un paquete usando solo su nombre de ejecutable
```

## Ecosistema de Datos y GitHub Actions

El repositorio de `moss` sigue un paradigma impulsado por datos (Data-Driven):

1. **`meta/apps.list`**: La fuente de la verdad. Un simple listado TSV (Nombre, Repo, Patrón, Descripción, **Exec**).
2. **`scripts/build-repo.sh`**: Script que consulta la API de GitHub Releases, extrae URLs de descarga dinámicas y precalcula los SHA256.
3. **`.github/workflows/update.yml`**: Bot automático que corre todos los días a las 03:00 AM UTC. Si detecta nuevas versiones, re-construye silenciosamente el `packages.tsv` y hace `push` al índice.

## Estado y Seguridad

Por paquete en `$MOSS_STATE_DIR/<nombre>/` (ej: `~/.local/share/moss/`): `manifest` (KEY=VALUE: name, version, url, sha256, prefix, tarball, installed_at), `files` (rutas instaladas para purga asincrónica con barra de progreso), y `manifest.bak`/`files.bak` para `rollback`.

Pipeline: descarga a caché -> verificación sha256 -> extracción a staging temporal -> aislamiento en `pkg/` u `opt/` -> creación de Symlink y .desktop inteligente -> copia con **rollback automático** si falla a mitad. 

## Códigos de Salida (Automatización)

`0` ok · `1` uso/no encontrado · `2` descarga (incluye índice sin caché) ·
`3` verificación · `4` instalación · `5` conflicto · `6` dependencia faltante.

## Estructura del Repositorio

```text
bin/moss                     # CLI de Moss (POSIX sh)
meta/apps.list               # Semilla del repositorio de GitHub (TSV)
scripts/build-repo.sh        # Generador del índice desde GitHub Releases
packages.tsv                 # Índice compilado automáticamente por el Bot (en la raíz)
.github/workflows/update.yml # CI/CD diario de automatización
tests/run_tests.sh           # Batería de pruebas unitarias
README.md                    # Este archivo
```
