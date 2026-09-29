#!/usr/bin/env python3
import sys
import json
import urllib.request
import re

def get_repo_info(repo):
    import os
    url = f"https://api.github.com/repos/{repo}"
    req = urllib.request.Request(url)
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"token {token}")
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode())
    except Exception as e:
        print(f"Error fetching repo info for {repo}: {e}")
        return None

def get_latest_release(repo):
    import os
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(url)
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"token {token}")
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode())
    except Exception as e:
        print(f"Error fetching release for {repo}: {e}")
        return None

def generate_regex(asset_name, app_name):
    # Reemplazar version con .*
    # Buscar patrones tipicos como v1.2.3 o 1.2.3
    version_pattern = re.compile(r'(v?\d+\.\d+\.\d+(-\w+)?)')
    match = version_pattern.search(asset_name)
    if match:
        asset_name = asset_name.replace(match.group(1), '.*')
    
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
    
    # Procesar y escribir directo al archivo
    with open(apps_list_path, "a") as out_file:
        for repo in repos:
            print(f"Analizando {repo}...")
            info = get_repo_info(repo)
            if not info: continue
            
            desc = info.get('description', 'Sin descripcion')
            if not desc: desc = "Sin descripcion"
            desc = desc.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ').strip()
            
            app_name = repo.split('/')[-1].lower()
            
            release = get_latest_release(repo)
            regex = "TARBALL"
            
            if release and 'assets' in release and len(release['assets']) > 0:
                assets = [a['name'] for a in release['assets']]
                target = None
                for a in assets:
                    al = a.lower()
                    if 'linux' in al and ('x86_64' in al or 'amd64' in al or 'x64' in al) and ('musl' in al or 'gnu' in al or al.endswith('.tar.gz') or al.endswith('.zip')):
                        target = a
                        break
                
                if not target:
                    for a in assets:
                        al = a.lower()
                        if 'linux' in al and ('x86_64' in al or 'amd64' in al or '64bit' in al or 'x64' in al):
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
            
    # Vaciar el archivo next.list si se leyó de ahí
    if len(sys.argv) <= 1 and os.path.exists(next_list_path):
        with open(next_list_path, "w") as f:
            pass
        print(f"-> {next_list_path} limpiado automáticamente.")

if __name__ == "__main__":
    main()
