# moss

Gestor de paquetes y tarballs (`.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar.zst`) estrictamente **Headless y CLI** escrito en **shell script puro**. 
Diseñado con una filosofía similar a `brew` o `nix`, aislando las instalaciones y generando symlinks inteligentes. Sin bashismos: corre nativamente bajo `dash` y `busybox ash`, lo que lo hace perfecto para CI/CD y scripts de automatización.

Actualmente el proyecto se encuentra en un estado muy joven, es estable para ciertas cosas pero todavia necesita tiempo para ser estable al completo.

## Dependencias

Obligatorias: `tar`, `find`, `sort`, `awk`, `sed`, `grep`, `date`, `cp`, `sha256sum` (o `shasum -a 256`, u `openssl`), `curl` **o** `wget`, `jq` (para compilar el índice).
Opcionales: `gpg` (verificación de firmas), `mktemp` (incluye un fallback nativo).

## Instalación

Moss cuenta con un script de instalación rápida (bootstrap) que descarga la última versión, la instala en un entorno aislado y configura automáticamente tu `PATH` para bash, zsh o fish.

Ejecuta el siguiente comando en tu terminal:

```bash
curl -sL https://raw.githubusercontent.com/ezequielgk/Moss/main/install.sh | bash
```

**Configuración del PATH:**
El instalador añadirá automáticamente la ruta segura `~/.local/moss/bin` a tu configuración de terminal (ej. `~/.bashrc`, `~/.zshrc`, o `~/.config/fish/config.fish`). Una vez instalado, asegúrate de **reiniciar tu terminal** o ejecutar el comando `source` que te indicará el instalador al finalizar.

### Actualización de Moss
Debido a que `moss` se administra a sí mismo como si fuera cualquier otro paquete, actualizar el gestor a la ultimísima versión es tan simple como hacer:
```bash
moss upgrade
```
## Arquitectura de Instalación y Sandboxing

A diferencia de gestores tradicionales que mezclan miles de archivos, `moss` emplea una estrategia de aislamiento estricto e inteligencia automatizada:

- **MOSS_PREFIX**: Por defecto se instala en `~/.local/moss` (usuario) o `/usr/local/moss` (con flag `--system`).
- **Paquetes Normales**: Se aíslan en la subcarpeta `pkg/<nombre_paquete>/`.
- **Paquetes Masivos (>100 archivos)**: Se aíslan en la subcarpeta `opt/<nombre_paquete>/` para evitar cuellos de botella y "suciendad" en el sistema.
- **Heurística de Ejecutables**: Moss lee una quinta columna `exec` en su índice de paquetes para determinar qué binario debe ser el "principal". De no existir, aplica una heurística nativa que busca y auto-selecciona el binario correcto dentro del tarball. El comando `install` también soporta `-e <binario>` para sobrescribir esto.
- **Symlinks y Escritorio Automáticos**: 
  - Expone limpia y automáticamente el binario detectado mediante un enlace simbólico en `~/.local/moss/bin/`. Moss utiliza este directorio aislado (en lugar del genérico `~/.local/bin/`) para evitar la contaminación cruzada con ejecutables instalados de otra manera en el sistema (Zero Pollution), asegurando un control absoluto del entorno y desinstalaciones prístinas.
  - Si se trata de un paquete, genera un archivo `.desktop` válido y limpio en `~/.local/share/applications` para que aparezca mágicamente en tu menú de aplicaciones (con `Terminal=false` por defecto). Si la aplicación es de consola (ej. `htop`, `kotofetch`), puedes usar el flag `-t` durante la instalación para que el `.desktop` se ejecute correctamente en tu terminal (`Terminal=true`).

## Uso Rápido (leer moss help | -h antes)

```sh
moss update                                 # Sincronizar repositorios y detectar actualizaciones
moss update foo foo-1.2.tar.gz              # Actualizar un paquete específico usando un tarball local
moss upgrade                                # Instalar iterativamente actualizaciones de paquetes instalados
moss upgrade -y                             # Actualizar todos los paquetes sin pedir confirmación
moss install foo                            # Instalar paquete por nombre desde el índice
moss install -t kotofetch                   # Instalar app de consola generando .desktop con Terminal=true
moss install -e my-bin foo.tar.gz           # Instalar archivo local forzando qué binario enlazar
moss install ./foo-1.0.0.tar.gz             # Instalar archivo local directamente (sin índice)
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
3. **`.github/workflows/update.yml`**: Bot automático que corre una vez por semana (los domingos a las 03:00 AM UTC). Si detecta nuevas versiones, re-construye silenciosamente el `packages.tsv` y hace `push` al índice.

## Estado y Seguridad

Por paquete en `$MOSS_STATE_DIR/<nombre>/` (ej: `~/.local/share/moss/`): `manifest` (KEY=VALUE: name, version, url, sha256, prefix, tarball, installed_at), `files` (rutas instaladas para purga asincrónica con barra de progreso), y `manifest.bak`/`files.bak` para `rollback`.

Pipeline: descarga a caché -> verificación sha256 -> extracción a staging temporal -> aislamiento en `pkg/` u `opt/` -> creación de Symlink y .desktop inteligente -> copia con **rollback automático** si falla a mitad. 

## Códigos de Salida (Automatización)

`0` ok · `1` uso/no encontrado · `2` descarga (incluye índice sin caché) ·
`3` verificación · `4` instalación · `5` conflicto · `6` dependencia faltante.

## Estructura del Repositorio

```text
bin/moss                     # CLI principal de Moss
meta/apps.list               # Semilla del repositorio de GitHub (TSV)
scripts/build-repo.sh        # Generador del índice desde GitHub Releases
packages.tsv                 # Índice compilado automáticamente por el Bot (en la raíz)
.github/workflows/update.yml # CI/CD diario de automatización
tests/run_tests.sh           # Batería de pruebas unitarias
README.md                    # Este archivo
```

## Limitaciones Conocidas

- **BusyBox (sh/awk/tar)**: Probado localmente contra los applets genéricos de BusyBox (`busybox sh -n`, `busybox awk`, `busybox tar`) corriendo sobre la libc del sistema de desarrollo (glibc). Se comprobó que no hay errores de sintaxis, la extracción de `.tar.gz` y `.tar.xz` funciona sin problemas, y el ciclo de `install` y `upgrade` corre a la perfección con las implementaciones provistas por BusyBox.
- **musl libc (Alpine u otra distro musl pura)**: **Todavía no validado** en un entorno aislado. Las pruebas exitosas de BusyBox no confirman compatibilidad total con `musl` de forma absoluta, ya que BusyBox fue corrido sobre la libc del host. Queda pendiente testear la ejecución del script dentro de un contenedor Alpine real puro.
- **AppImage en musl puro**: La gran mayoría de los paquetes distribuidos como AppImage están compilados dinámicamente contra `glibc` y no funcionarán de forma nativa en un entorno puramente `musl` sin instalar una capa de compatibilidad como `gcompat`. Esto no es un bug de Moss, sino una restricción estricta de la arquitectura del archivo AppImage.
