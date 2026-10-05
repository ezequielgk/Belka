# belka

Gestor de paquetes y tarballs (`.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar.zst`) estrictamente **Headless y CLI** escrito en **shell script puro**.
Diseñado con una filosofía similar a `brew` o `nix`, aislando las instalaciones y generando symlinks inteligentes. Sin bashismos: corre nativamente bajo `dash` y `busybox ash`, lo que lo hace perfecto para entornos minimalistas, servidores y escritorios sin depender de un shell específico.

Actualmente el proyecto se encuentra en un estado muy joven, es estable para ciertas cosas pero todavía necesita tiempo para ser estable al completo.

## Dependencias

Obligatorias: `tar`, `find`, `sort`, `awk`, `sed`, `grep`, `date`, `cp`, `sha256sum` (o `shasum -a 256`, u `openssl`), `curl` **o** `wget`, `jq` (para compilar el índice).
Opcionales: `gpg` (verificación de firmas), `mktemp` (incluye un fallback nativo).

## Instalación

Belka cuenta con un script de instalación rápida (bootstrap) que descarga la última versión, la instala en un entorno aislado y configura automáticamente tu `PATH` para bash, zsh o fish.

Ejecuta el siguiente comando en tu terminal:

```bash
curl -sL https://raw.githubusercontent.com/ezequielgk/Belka/main/install.sh | bash
```

**Configuración del PATH:**
El instalador añadirá automáticamente la ruta segura `~/.local/belka/bin` a tu configuración de terminal (ej. `~/.bashrc`, `~/.zshrc`, o `~/.config/fish/config.fish`). Una vez instalado, asegúrate de recargar tu shell o abrir una nueva sesión para que el comando `belka` quede disponible.

### Actualización de Belka
Debido a que `belka` se administra a sí mismo como si fuera cualquier otro paquete, actualizar el gestor a la ultimísima versión es tan simple como hacer:
```bash
belka upgrade
```
## Arquitectura de Instalación y Sandboxing

A diferencia de gestores tradicionales que mezclan miles de archivos, `belka` emplea una estrategia de aislamiento estricto e inteligencia automatizada:

- **BELKA_PREFIX**: Por defecto se instala en `~/.local/belka` (usuario) o `/usr/local/belka` (con flag `--system`).
- **Paquetes Normales**: Se aíslan en la subcarpeta `pkg/<nombre_paquete>/`.
- **Paquetes Masivos (>100 archivos)**: Se aíslan en la subcarpeta `opt/<nombre_paquete>/` para evitar cuellos de botella y "suciedad" en el sistema.
- **Heurística de Ejecutables**: Belka lee una quinta columna `exec` (de un total de hasta 10 columnas en `packages.tsv`) para determinar qué binario debe ser el "principal". De no existir, aplica una heurística de deducción por nombre y patrones.
- **Symlinks y Escritorio Automáticos**:
  - Expone limpia y automáticamente el binario detectado mediante un enlace simbólico en `~/.local/belka/bin/`. Belka utiliza este directorio aislado (en lugar del genérico `~/.local/bin/`) para evitar conflictos globales.
  - Si se trata de un paquete, genera un archivo `.desktop` válido y limpio en `~/.local/share/applications` para que aparezca mágicamente en tu menú de aplicaciones (con `Terminal=false` por defecto en la mayoría de casos).

## Uso Rápido (leer belka help | -h antes)

```sh
belka update                                 # Sincronizar repositorios y detectar actualizaciones
belka update foo foo-1.2.tar.gz              # Actualizar un paquete específico usando un tarball local
belka upgrade                                # Instalar iterativamente actualizaciones de paquetes instalados
belka upgrade -y                             # Actualizar todos los paquetes sin pedir confirmación
belka install foo                            # Instalar paquete por nombre desde el índice
belka install -t kotofetch                   # Instalar app de consola generando .desktop con Terminal=true
belka install -e my-bin foo.tar.gz           # Instalar archivo local forzando qué binario enlazar
belka install ./foo-1.0.0.tar.gz             # Instalar archivo local directamente (sin índice)
belka list                                   # Tabla limpia de instalados (ID, Binario Real, Versión, Fecha)
belka search foo                             # Buscar en el índice
belka info foo                               # Mostrar información de estado detallada
belka verify foo                             # Verificar checksums del tarball local
belka rollback foo                           # Volver a la versión previa instalada del paquete
belka remove foo                             # Desinstalar mediante su ID de paquete original
belka remove my-foo-bin                      # Desinstalar un paquete usando solo su nombre de ejecutable
```

## Ecosistema de Datos y GitHub Actions

El repositorio de `belka` sigue un paradigma impulsado por datos (Data-Driven):

1. **`meta/apps.list`**: La fuente de la verdad. Un simple listado TSV (Nombre, Repo, Patrón, Descripción, **Exec**).
2. **`scripts/build-repo.sh`**: Script que consulta la API de GitHub Releases, extrae URLs de descarga dinámicas y precalcula los SHA256.
3. **`.github/workflows/update.yml`**: Bot automático que corre una vez por semana (los domingos a las 03:00 AM UTC). Si detecta nuevas versiones, re-construye silenciosamente el `packages.tsv` y hace un commit con la nueva información del índice.

## Estado y Seguridad

Por paquete en `$BELKA_STATE_DIR/<nombre>/` (ej: `~/.local/share/belka/`): `manifest` (KEY=VALUE: name, version, url, sha256, prefix, tarball, installed_at), `files` (rutas instaladas para purga asíncrona de archivos huérfanos), `history` (instantáneas previas para rollback), `bin` (symlinks y .desktop generados), y un `state` interno para llevar trazabilidad del proceso.

Pipeline: descarga a caché -> verificación sha256 -> extracción a staging temporal -> aislamiento en `pkg/` u `opt/` -> creación de Symlink y .desktop inteligente -> copia con **rollback automático** y limpieza segura cuando algo falla.

## Códigos de Salida (Automatización)

`0` ok · `1` uso/no encontrado · `2` descarga (incluye índice sin caché) ·
`3` verificación · `4` instalación · `5` conflicto · `6` dependencia faltante.

## Estructura del Repositorio

```text
bin/belka                     # CLI principal de Belka
meta/apps.list               # Semilla del repositorio de GitHub (TSV)
scripts/build-repo.sh        # Generador del índice desde GitHub Releases
packages.tsv                 # Índice compilado automáticamente por el Bot (en la raíz)
.github/workflows/update.yml # CI/CD diario de automatización
tests/run_tests.sh           # Batería de pruebas unitarias
README.md                    # Este archivo
```

## Limitaciones Conocidas

- **BusyBox (sh/awk/tar)**: Probado localmente contra los applets genéricos de BusyBox (`busybox sh -n`, `busybox awk`, `busybox tar`) corriendo sobre la libc del sistema de desarrollo (glibc). Se confirma compatibilidad con configuraciones mínimas, pero no se garantiza a nivel absoluto sobre todas las variantes de libc.
- **musl libc (Alpine u otra distro musl pura)**: **Todavía no validado** en un entorno aislado. Las pruebas exitosas de BusyBox no confirman compatibilidad total con `musl` de forma absoluta, ya que cada envoltorio de libc puede cambiar el comportamiento de `tar`, `awk` y `sh`.

