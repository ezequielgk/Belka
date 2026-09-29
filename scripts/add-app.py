#!/usr/bin/env python3
import sys
import os
import json
import urllib.request
import re

def normalize_repo(url: str):
    """
    Limpia y normaliza la URL del repositorio.
    Retorna una tupla (plataforma, cadena_normalizada).
    """
    url = url.split('?')[0].strip('/')
    if url.endswith('.git'):
        url = url[:-4]
        
    if "codeberg.org" in url:
        return "codeberg", url
    elif "gitlab.com" in url:
        return "gitlab", url
    elif "github.com" in url:
        path = url.split("github.com/")[-1]
        return "github", path
    else:
        # Formato corto autor/repo asume github
        return "github", url

def get_repo_info(forge, repo_str):
    if forge == "codeberg":
        path = repo_str.split("codeberg.org/")[-1]
        url = f"https://codeberg.org/api/v1/repos/{path}"
    elif forge == "gitlab":
        path = repo_str.split("gitlab.com/")[-1]
        enc_path = path.replace("/", "%2F")
        url = f"https://gitlab.com/api/v4/projects/{enc_path}"
    else:
        url = f"https://api.github.com/repos/{repo_str}"
        
    req = urllib.request.Request(url)
    token = os.environ.get("GITHUB_TOKEN")
    if token and forge == "github":
        req.add_header("Authorization", f"token {token}")
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode())
    except Exception as e:
        print(f"Error fetching repo info para {repo_str}: {e}")
        return None

def get_latest_release(forge, repo_str):
    if forge == "codeberg":
        path = repo_str.split("codeberg.org/")[-1]
        url = f"https://codeberg.org/api/v1/repos/{path}/releases/latest"
    elif forge == "gitlab":
        path = repo_str.split("gitlab.com/")[-1]
        enc_path = path.replace("/", "%2F")
        url = f"https://gitlab.com/api/v4/projects/{enc_path}/releases/permalink/latest"
    else:
        url = f"https://api.github.com/repos/{repo_str}/releases/latest"

    req = urllib.request.Request(url)
    token = os.environ.get("GITHUB_TOKEN")
    if token and forge == "github":
        req.add_header("Authorization", f"token {token}")
    try:
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode())
            if forge == "gitlab" and "assets" in data and "links" in data["assets"]:
                data["assets"] = data["assets"]["links"]
            return data
    except Exception as e:
        print(f"Error fetching release para {repo_str}: {e}")
        return None

def generate_regex(asset_name, app_name):
    version_pattern = re.compile(r'(v?\d+\.\d+(\.\d+)?(-[a-zA-Z0-9]+)?)')
    match = version_pattern.search(asset_name)
    if match:
        asset_name = asset_name.replace(match.group(1), '.*')
    else:
        version_pattern_2 = re.compile(r'(\d+\.\d+)')
        match2 = version_pattern_2.search(asset_name)
        if match2:
            asset_name = asset_name.replace(match2.group(1), '.*')
    
    asset_name = asset_name.replace('.', r'\.')
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

def sort_apps_list(apps_list_path):
    if not os.path.exists(apps_list_path):
        return
        
    with open(apps_list_path, 'r') as f:
        lines = f.readlines()
        
    if not lines:
        return
        
    headers = []
    app_lines = []
    
    for line in lines:
        if line.startswith('#') or not line.strip():
            headers.append(line)
        else:
            app_lines.append(line)
            
    app_lines.sort(key=lambda x: x.split('\t')[0].lower())
    
    with open(apps_list_path, 'w') as f:
        for header in headers:
            f.write(header)
        for line in app_lines:
            f.write(line if line.endswith('\n') else line + '\n')
            
    print("-> meta/apps.list reescrito y ordenado alfabéticamente de la A a la Z.")

def main():
    next_list_path = "meta/next.list"
    apps_list_path = "meta/apps.list"
    
    repos_to_process = []
    
    # 1. Leer entradas
    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            repos_to_process.append((arg, None))
    else:
        if os.path.exists(next_list_path):
            with open(next_list_path, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"): continue
                    parts = re.split(r'[\t ]+', line)
                    url = parts[0]
                    alias = parts[1] if len(parts) > 1 else None
                    repos_to_process.append((url, alias))
        else:
            print(f"Uso: ./add-app.py autor/repo [autor2/repo2 ...]")
            print(f"O crea un archivo {next_list_path} con un repo por linea (alias opcional).")
            sys.exit(1)
            
    if not repos_to_process:
        print("No hay repositorios para procesar.")
        sys.exit(0)
        
    # 2. Cargar entradas existentes para prevenir duplicados
    existing_apps = set()
    existing_repos = set()
    if os.path.exists(apps_list_path):
        with open(apps_list_path, 'r') as f:
            for line in f:
                if not line.strip() or line.startswith('#'): continue
                parts = line.strip().split('\t')
                if len(parts) > 1:
                    existing_apps.add(parts[0].lower())
                    existing_repos.add(parts[1].lower())
    
    failed_repos = []
    added_any = False
    
    # 3. Procesar y escribir
    with open(apps_list_path, "a") as out_file:
        for raw_url, alias in repos_to_process:
            forge, norm_repo = normalize_repo(raw_url)
            app_name = alias.lower() if alias else norm_repo.split('/')[-1].lower()
            
            if app_name in existing_apps or norm_repo.lower() in existing_repos:
                print(f"[SKIP] {app_name} ({norm_repo}) ya está indexado. Ignorando duplicado.")
                continue
                
            print(f"Analizando {app_name} en {norm_repo}...")
            info = get_repo_info(forge, norm_repo)
            if not info: 
                failed_repos.append(raw_url if not alias else f"{raw_url}\t{alias}")
                continue
            
            desc = info.get('description', 'Sin descripcion')
            if not desc: desc = "Sin descripcion"
            desc = desc.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ').strip()
            
            release = get_latest_release(forge, norm_repo)
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
            
            line = f"{app_name}\t{norm_repo}\t{regex}\t{desc}\t{exec_name}\t{categoria}\t{is_terminal}\n"
            out_file.write(line)
            existing_apps.add(app_name)
            existing_repos.add(norm_repo.lower())
            added_any = True
            print(f"  -> {app_name} agregado exitosamente!")
            
    # 4. Ordenar archivo si se agrego algo
    if added_any:
        sort_apps_list(apps_list_path)

    # Actualizar o vaciar next.list
    if len(sys.argv) <= 1 and os.path.exists(next_list_path):
        if failed_repos:
            with open(next_list_path, "w") as f:
                for r in failed_repos:
                    f.write(f"{r}\n")
            print(f"-> {next_list_path} actualizado: se conservaron {len(failed_repos)} repositorios fallidos.")
        else:
            with open(next_list_path, "w") as f:
                pass
            print(f"-> {next_list_path} limpiado automáticamente.")

if __name__ == "__main__":
    main()
