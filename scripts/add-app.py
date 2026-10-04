#!/usr/bin/env python3
import sys
import os
import json
import urllib.request
import re

def normalize_repo(url: str):
    url = url.split('?')[0].strip('/')
    if url.endswith('.git'):
        url = url[:-4]
        
    if "codeberg.org" in url:
        path = url.split("codeberg.org/")[-1]
        return "codeberg", path, url
    elif "gitlab.com" in url:
        path = url.split("gitlab.com/")[-1]
        return "gitlab", path, url
    elif "github.com" in url:
        path = url.split("github.com/")[-1]
        return "github", path, url
    else:
        return "github", url, url

def get_repo_info(forge: str, path: str):
    try:
        if forge == "codeberg":
            api_url = f"https://codeberg.org/api/v1/repos/{path}"
        elif forge == "gitlab":
            api_url = f"https://gitlab.com/api/v4/projects/{urllib.parse.quote(path, safe='')}"
        else:
            api_url = f"https://api.github.com/repos/{path}"
            
        req = urllib.request.Request(api_url)
        if forge == "github" and os.environ.get("GITHUB_TOKEN"):
            req.add_header("Authorization", f"Bearer {os.environ['GITHUB_TOKEN']}")
            
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode('utf-8'))
    except Exception as e:
        print(f"Error obteniendo info de {forge}/{path}: {e}")
        return None

def get_latest_release(forge: str, path: str):
    try:
        if forge == "codeberg":
            api_url = f"https://codeberg.org/api/v1/repos/{path}/releases/latest"
        elif forge == "gitlab":
            api_url = f"https://gitlab.com/api/v4/projects/{urllib.parse.quote(path, safe='')}/releases/permalink/latest"
        else:
            api_url = f"https://api.github.com/repos/{path}/releases/latest"
            
        req = urllib.request.Request(api_url)
        if forge == "github" and os.environ.get("GITHUB_TOKEN"):
            req.add_header("Authorization", f"Bearer {os.environ['GITHUB_TOKEN']}")
            
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode('utf-8'))
    except Exception as e:
        print(f"Error obteniendo release de {forge}/{path}: {e}")
        return None

def generate_regex(filename: str, app_name: str):
    name, ext = os.path.splitext(filename)
    if filename.lower().endswith('.tar.gz'):
        name = filename[:-7]
        ext = '.tar.gz'
    elif filename.lower().endswith('.tar.xz'):
        name = filename[:-7]
        ext = '.tar.xz'
    
    parts = re.split(r'([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[a-zA-Z0-9]+)*)', name)
    if len(parts) > 1:
        regex = parts[0] + ".*" + "".join(parts[2:]) + ext.replace('.', r'\.')
        return regex
    
    return filename.replace('.', r'\.')

def get_category(desc: str, app_name: str):
    desc_lower = desc.lower()
    if any(x in desc_lower for x in ['game', 'juego', 'emulator']):
        return "Game"
    if any(x in desc_lower for x in ['music', 'audio', 'player', 'sound']):
        return "Audio"
    if any(x in desc_lower for x in ['video', 'movie', 'player']):
        return "Video"
    if any(x in desc_lower for x in ['editor', 'ide', 'code', 'develop']):
        return "Development"
    if any(x in desc_lower for x in ['browser', 'web', 'internet']):
        return "Network"
    return "Utility"

def sort_apps_list(path: str):
    if not os.path.exists(path): return
    with open(path, 'r') as f:
        lines = f.readlines()
        
    headers = [l for l in lines if l.strip() and l.startswith('#')]
    apps = [l for l in lines if l.strip() and not l.startswith('#')]
    
    apps.sort(key=lambda x: x.split('\t')[0].lower())
    
    with open(path, 'w') as f:
        for h in headers: f.write(h)
        for a in apps: f.write(a)

def main():
    import urllib.parse
    tar_list_path = "meta/tar.list"
    appimages_list_path = "meta/appimages.list"
    next_list_path = "meta/next.list"
    
    repos_to_process = []
    
    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            parts = arg.split(maxsplit=2)
            alias = parts[1] if len(parts) > 1 else None
            template = parts[2] if len(parts) > 2 else None
            repos_to_process.append((parts[0], alias, template))
    else:
        if os.path.exists(next_list_path):
            with open(next_list_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'): continue
                    parts = line.split(maxsplit=2)
                    url = parts[0]
                    alias = parts[1] if len(parts) > 1 else None
                    template = parts[2] if len(parts) > 2 else None
                    repos_to_process.append((url, alias, template))
        else:
            print(f"Uso: ./add-app.py autor/repo [autor2/repo2 ...]")
            print(f"O crea un archivo {next_list_path} con un repo por linea (alias y template opcional).")
            sys.exit(1)
            
    if not repos_to_process:
        print("No hay repositorios para procesar.")
        sys.exit(0)
        
    existing_tar_apps = set()
    existing_tar_repos = set()
    if os.path.exists(tar_list_path):
        with open(tar_list_path, 'r') as f:
            for line in f:
                if not line.strip() or line.startswith('#'): continue
                parts = line.strip().split('\t')
                if len(parts) > 1:
                    existing_tar_apps.add(parts[0].lower())
                    existing_tar_repos.add(parts[1].lower())
                    
    existing_appimage_apps = set()
    existing_appimage_repos = set()
    if os.path.exists(appimages_list_path):
        with open(appimages_list_path, 'r') as f:
            for line in f:
                if not line.strip() or line.startswith('#'): continue
                parts = line.strip().split('\t')
                if len(parts) > 1:
                    existing_appimage_apps.add(parts[0].lower())
                    existing_appimage_repos.add(parts[1].lower())
    
    failed_repos = []
    added_tar = False
    added_appimage = False
    
    for raw_url, alias, template in repos_to_process:
        is_direct = False
        url_clean = raw_url.lower().split('?')[0]
        if any(url_clean.endswith(ext) for ext in ['.tar.gz', '.tar.xz', '.txz', '.zip', '.tar', '.appimage']):
            is_direct = True
        elif raw_url.startswith('http') and not any(x in raw_url.lower() for x in ['github.com', 'gitlab.com', 'codeberg.org']):
            is_direct = True

        if is_direct and not (template and template.startswith('TEMPLATE|')):
            match = re.search(r'([0-9]+(?:\.[0-9]+)+)', raw_url)
            if match:
                version = match.group(1)
                template_url = raw_url.replace(version, '@VERSION@')
            else:
                version = 'latest'
                template_url = raw_url

            filename = raw_url.split('/')[-1].split('?')[0]
            if alias:
                app_name = alias
            else:
                app_name = filename
                if version != 'latest':
                    app_name = app_name.replace(version, '')
                for ext in ['.tar.gz', '.tar.xz', '.txz', '.zip', '.tar', '.appimage', '.AppImage']:
                    app_name = app_name.replace(ext, '')
                app_name = app_name.strip('-_.').lower()
                if not app_name: app_name = "app"

            template = f"TEMPLATE|{template_url}|{version}"
            raw_url = f"external/{app_name}"

        forge, norm_repo, out_repo = normalize_repo(raw_url)
        
        is_inrepo = (alias and alias.lower() == 'inrepo')
        
        if is_inrepo:
            app_name = norm_repo.split('/')[-1].lower()
            exec_name_override = template if template else app_name
        else:
            app_name = alias.lower() if alias else norm_repo.split('/')[-1].lower()
            exec_name_override = None
            
        print(f"Analizando {app_name} en {norm_repo}...")
        if template and template.startswith('TEMPLATE|'):
            info = {'description': 'Aplicacion Externa'}
        else:
            info = get_repo_info(forge, norm_repo)
        
        if not info: 
            failed_repos.append(raw_url if not alias else (f"{raw_url}\t{alias}" if not template else f"{raw_url}\t{alias}\t{template}"))
            continue
        
        desc = info.get('description', 'Sin descripcion')
        if not desc: desc = "Sin descripcion"
        desc = desc.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ').strip()
        
        if is_inrepo:
            release = {'assets': [{'name': 'dummy'}]}
        elif template and template.startswith('TEMPLATE|'):
            release = {'assets': [{'name': 'dummy'}]}
        else:
            release = get_latest_release(forge, norm_repo)
        
        if is_inrepo or (template and template.startswith('TEMPLATE|')):
            # Skip asset checking
            pass
        elif not release or 'assets' not in release or len(release['assets']) == 0:
            print(f"  -> Error: no se encontraron assets para {app_name}")
            failed_repos.append(raw_url if not alias else (f"{raw_url}\t{alias}" if not template else f"{raw_url}\t{alias}\t{template}"))
            continue
            
        assets = [a['name'] for a in release['assets']]
        
        def is_linux_amd64(name):
            al = name.lower()
            if any(x in al for x in ['windows', 'win32', 'darwin', 'macos']):
                return False
            if any(x in al for x in ['arm', 'aarch64', 'riscv', 'mips', 's390x', 'ppc']):
                return False
            if any(x in al for x in ['i386', '386', 'ia32', 'i686']) and 'x86_64' not in al:
                return False
            
            if 'linux' in al and any(x in al for x in ['x86_64', 'amd64', 'x64', '64bit']):
                return True
            if any(x in al for x in ['x86_64', 'amd64', 'x64']):
                return True
            if 'appimage' in al:
                return True
            return False

        hint = template if template and not template.startswith('TEMPLATE|') else None

        def get_best_target(exts):
            filtered = [a for a in assets if any(a.lower().endswith(e) for e in exts) and not a.lower().endswith('.sig')]
            
            if hint:
                hint_filtered = [a for a in filtered if re.search(hint, a, re.IGNORECASE)]
                if hint_filtered:
                    return hint_filtered[0]
            
            for a in filtered:
                if is_linux_amd64(a) and 'gnu' in a.lower(): return a
            for a in filtered:
                if is_linux_amd64(a) and 'musl' not in a.lower(): return a
            for a in filtered:
                if is_linux_amd64(a) and 'musl' in a.lower(): return a
                
            for a in filtered:
                al = a.lower()
                if 'linux' in al or ('binary' in al) or ('appimage' in al):
                    if not any(x in al for x in ['windows', 'darwin', 'macos', 'arm', 'aarch64', 'i386']):
                        return a
                        
            # Final fallback: if it doesn't contain ANY other OS/Arch, assume it is generic linux amd64
            for a in filtered:
                al = a.lower()
                if not any(x in al for x in ['windows', 'win32', 'darwin', 'macos', 'arm', 'aarch64', 'i386', '386', 'ia32', 'i686', 'riscv', 'mips', 's390x', 'ppc']):
                    return a
                    
            return None

        def get_standalone_binary():
            bad_exts = ('.deb', '.rpm', '.apk', '.msi', '.exe', '.dmg', '.pkg', '.sig', '.sha256', '.txt', '.md', '.pem', '.sum', '.pub', '.json', '.yaml', '.yml', '.sbom')
            filtered = [a for a in assets if not any(a.lower().endswith(e) for e in bad_exts)]
            arch_exts = ('.tar.gz', '.tar.xz', '.txz', '.zip', '.tar', '.appimage')
            filtered = [a for a in filtered if not any(a.lower().endswith(e) for e in arch_exts)]
            
            if hint:
                hint_filtered = [a for a in filtered if re.search(hint, a, re.IGNORECASE)]
                if hint_filtered:
                    return hint_filtered[0]
            
            for a in filtered:
                if is_linux_amd64(a) and 'gnu' in a.lower(): return a
            for a in filtered:
                if is_linux_amd64(a) and 'musl' not in a.lower(): return a
            for a in filtered:
                if is_linux_amd64(a) and 'musl' in a.lower(): return a
                
            for a in filtered:
                al = a.lower()
                if 'linux' in al or ('binary' in al):
                    if not any(x in al for x in ['windows', 'darwin', 'macos', 'arm', 'aarch64', 'i386']):
                        return a
            return None

        if is_inrepo:
            target_tar = "INREPO"
            target_appimage = None
        elif template and template.startswith('TEMPLATE|'):
            if 'appimage' in template.lower():
                target_appimage = template
                target_tar = None
            else:
                target_tar = template
                target_appimage = None
        else:
            target_tar = get_best_target(('.tar.gz', '.tar.xz', '.txz', '.zip', '.tar'))
            if not target_tar:
                target_tar = get_standalone_binary()
            target_appimage = get_best_target(('.appimage',))
        
        found_any = False
        exec_name = exec_name_override if exec_name_override else app_name
        categoria = get_category(desc, app_name)
        is_terminal = "Y" if "terminal" in desc.lower() or "cli" in desc.lower() else "N"
        
        if target_tar:
            if app_name not in existing_tar_apps and out_repo.lower() not in existing_tar_repos:
                if target_tar.startswith('TEMPLATE|') or target_tar == 'INREPO':
                    regex = target_tar
                else:
                    regex = generate_regex(target_tar, app_name)
                line = f"{app_name}\t{out_repo}\t{regex}\t{desc}\t{exec_name}\t{categoria}\t{is_terminal}\n"
                with open(tar_list_path, "a") as out_file:
                    out_file.write(line)
                existing_tar_apps.add(app_name)
                existing_tar_repos.add(out_repo.lower())
                added_tar = True
                found_any = True
                print(f"  -> {app_name} agregado a tar.list exitosamente!")
            else:
                print(f"  -> [SKIP] {app_name} ya existe en tar.list.")
                found_any = True
                
        if target_appimage:
            if app_name not in existing_appimage_apps and out_repo.lower() not in existing_appimage_repos:
                regex = target_appimage if target_appimage.startswith('TEMPLATE|') else generate_regex(target_appimage, app_name)
                line = f"{app_name}\t{out_repo}\t{regex}\t{desc}\t{exec_name}\t{categoria}\t{is_terminal}\n"
                with open(appimages_list_path, "a") as out_file:
                    out_file.write(line)
                existing_appimage_apps.add(app_name)
                existing_appimage_repos.add(out_repo.lower())
                added_appimage = True
                found_any = True
                print(f"  -> {app_name} agregado a appimages.list exitosamente!")
            else:
                print(f"  -> [SKIP] {app_name} ya existe en appimages.list.")
                found_any = True
                
        if not found_any:
            print(f"  -> Advertencia: No se encontro asset Linux compatible para {app_name}.")
            failed_repos.append(raw_url if not alias else f"{raw_url}\t{alias}")

    if added_tar: sort_apps_list(tar_list_path)
    if added_appimage: sort_apps_list(appimages_list_path)

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
