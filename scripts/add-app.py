#!/usr/bin/env python3
import sys
import json
import urllib.request
import re

def parse_repo_url(repo_url):
    if "codeberg.org" in repo_url:
        path = repo_url.split("codeberg.org/")[-1].strip('/')
        return "codeberg", path
    elif "gitlab.com" in repo_url:
        path = repo_url.split("gitlab.com/")[-1].strip('/')
        return "gitlab", path
    else:
        path = repo_url.split("github.com/")[-1].strip('/')
        return "github", path

def get_repo_info(repo_url):
    import os
    forge, path = parse_repo_url(repo_url)
    if forge == "codeberg":
        url = f"https://codeberg.org/api/v1/repos/{path}"
    elif forge == "gitlab":
        enc_path = path.replace("/", "%2F")
        url = f"https://gitlab.com/api/v4/projects/{enc_path}"
    else:
        url = f"https://api.github.com/repos/{path}"
        
    req = urllib.request.Request(url)
    token = os.environ.get("GITHUB_TOKEN")
    if token and forge == "github":
        req.add_header("Authorization", f"token {token}")
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode())
    except Exception as e:
        print(f"Error fetching repo info for {repo_url}: {e}")
        return None

def get_latest_release(repo_url):
    import os
    forge, path = parse_repo_url(repo_url)
    if forge == "codeberg":
        url = f"https://codeberg.org/api/v1/repos/{path}/releases/latest"
    elif forge == "gitlab":
        enc_path = path.replace("/", "%2F")
        url = f"https://gitlab.com/api/v4/projects/{enc_path}/releases/permalink/latest"
    else:
        url = f"https://api.github.com/repos/{path}/releases/latest"

    req = urllib.request.Request(url)
    token = os.environ.get("GITHUB_TOKEN")
    if token and forge == "github":
        req.add_header("Authorization", f"token {token}")
    try:
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode())
            # Normalize GitLab assets to look like GitHub/Codeberg
            if forge == "gitlab" and "assets" in data and "links" in data["assets"]:
                data["assets"] = data["assets"]["links"]
            return data
    except Exception as e:
        print(f"Error fetching release for {repo_url}: {e}")
        return None

def generate_regex(asset_name, app_name):
    # Buscar patrones tipicos de versiones, ej: v1.2.3, 1.2.3, 1.4.4-1, 156.0.1-1
    version_pattern = re.compile(r'(v?\d+\.\d+(\.\d+)?(-[a-zA-Z0-9]+)?)')
    match = version_pattern.search(asset_name)
    if match:
        asset_name = asset_name.replace(match.group(1), '.*')
    else:
        # Intento secundario: version simple ej 1.28
        version_pattern_2 = re.compile(r'(\d+\.\d+)')
        match2 = version_pattern_2.search(asset_name)
        if match2:
            asset_name = asset_name.replace(match2.group(1), '.*')
    
    # Reemplazar arquitecturas especificas por .* o agruparlas si es necesario
    # Por seguridad escapamos los puntos
    asset_name = asset_name.replace('.', r'\.')
    # Restaurar el .* que acabamos de romper accidentalmente con el escape de puntos
    asset_name = asset_name.replace(r'\.*', '.*')
    
    return asset_name

def get_category(desc, name):
    desc = desc.lower()
    name = name.lower()
    if any(k in desc or k in name for k in ["fetch", "system", "disk", "usage", "resource", "monitor", "kernel", "hw", "watch", "process", "log file", "secrets", "emulator", "prompt"]):
        return "System"
    if any(k in desc or k in name for k in ["git", "linter", "formatter", "python", "json", "yaml", "xml", "node", "compiler", "hex", "markdown", "docker", "kubernetes", "k8s", "code", "dev", "sql", "bash"]):
        return "Development"
    if any(k in desc or k in name for k in ["http", "network", "curl", "dns", "ping", "web", "serve", "download", "bandwidth", "bittorrent", "bluetooth", "grpc", "discord"]):
        return "Network"
    if any(k in desc or k in name for k in ["archive", "pack", "compress", "zip", "tar"]):
        return "Utility"
    return "Utility"

def main():
    import os
    repos = []
    
    # Si pasaste argumentos por terminal, usalos
    if len(sys.argv) > 1:
        repos = sys.argv[1:]
    else:
        # Si no, intentar leer meta/next.list
        next_list_path = "meta/next.list"
        if os.path.exists(next_list_path):
            with open(next_list_path, "r") as f:
                repos = [line.strip() for line in f if line.strip() and not line.startswith("#")]
        else:
            print(f"Uso: ./add-app.py autor/repo [autor2/repo2 ...]")
            print(f"O crea un archivo {next_list_path} con un repo por linea.")
            sys.exit(1)
            
    if not repos:
        print("No hay repositorios para procesar.")
        sys.exit(0)
        
    apps_list_path = "meta/apps.list"
    
    failed_repos = []
    
    # Procesar y escribir directo al archivo
    with open(apps_list_path, "a") as out_file:
        for repo in repos:
            print(f"Analizando {repo}...")
            info = get_repo_info(repo)
            if not info: 
                failed_repos.append(repo)
                continue
            
            desc = info.get('description', 'Sin descripcion')
            if not desc: desc = "Sin descripcion"
            desc = desc.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ').strip()
            
            app_name = repo.split('/')[-1].lower()
            
            release = get_latest_release(repo)
            regex = "TARBALL"
            
            if release and 'assets' in release and len(release['assets']) > 0:
                assets = [a['name'] for a in release['assets']]
                target = None
                
                valid_exts = ('.tar.gz', '.tar.xz', '.txz', '.zip', '.tar')
                filtered_assets = [a for a in assets if any(a.lower().endswith(ext) for ext in valid_exts) and not a.lower().endswith('.sig')]
                
                def is_linux_amd64(name):
                    al = name.lower()
                    if any(x in al for x in ['windows', 'win32', 'darwin', 'mac', 'apple', 'arm64', 'aarch64', 'armv7', 'armhf', 'i386', '386', 'ia32']):
                        return False
                    if 'linux' in al and any(x in al for x in ['x86_64', 'amd64', 'x64', '64bit']):
                        return True
                    if any(x in al for x in ['x86_64', 'amd64', 'x64']):
                        return True
                    return False

                # Nivel 1: Linux x86_64 explicito y formato musl/gnu
                for a in filtered_assets:
                    al = a.lower()
                    if is_linux_amd64(a) and ('musl' in al or 'gnu' in al):
                        target = a
                        break
                        
                # Nivel 2: Cualquier archivo linux x86_64 válido
                if not target:
                    for a in filtered_assets:
                        if is_linux_amd64(a):
                            target = a
                            break
                            
                # Nivel 3: Algún asset genérico de linux
                if not target:
                    for a in filtered_assets:
                        al = a.lower()
                        if 'linux' in al or ('binary' in al):
                            if not any(x in al for x in ['windows', 'darwin', 'mac', 'arm', 'aarch64', 'i386']):
                                target = a
                                break
                            
                if target:
                    regex = generate_regex(target, app_name)
                else:
                    print(f"  -> Advertencia: No se encontro asset Linux x86_64 claro. Revisa apps.list")
                    regex = "REEMPLAZAME"
            
            exec_name = app_name
            categoria = get_category(desc, app_name)
            is_terminal = "Y"
            
            line = f"{app_name}\t{repo}\t{regex}\t{desc}\t{exec_name}\t{categoria}\t{is_terminal}\n"
            out_file.write(line)
            print(f"  -> Agregado a {apps_list_path} exitosamente!")
            
    # Actualizar o vaciar el archivo next.list si se leyó de ahí
    if len(sys.argv) <= 1 and os.path.exists(next_list_path):
        if failed_repos:
            with open(next_list_path, "w") as f:
                for r in failed_repos:
                    f.write(f"{r}\n")
            print(f"-> {next_list_path} actualizado: se conservaron {len(failed_repos)} repositorios fallidos para el proximo intento.")
        else:
            with open(next_list_path, "w") as f:
                pass
            print(f"-> {next_list_path} limpiado automáticamente (todos exitosos).")

if __name__ == "__main__":
    main()
