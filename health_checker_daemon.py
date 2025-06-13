
import sys
import re
import json
import os
import time
import subprocess
import argparse
from collections import OrderedDict
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    from croniter import croniter
except ImportError:
    print("错误: Python 模块 'croniter' 未安装。请运行 'pip3 install croniter'。", file=sys.stderr)
    sys.exit(1)

REALM_CONFIG_DIR = os.environ.get("REALM_CONFIG_DIR", "/etc/realm")
REALM_CONFIG_FILE = os.environ.get("REALM_CONFIG_FILE", os.path.join(REALM_CONFIG_DIR, "config.toml"))
HEALTH_CHECKS_FILE = os.environ.get("HEALTH_CHECKS_FILE", os.path.join(REALM_CONFIG_DIR, "health_checks.conf"))
STATE_BACKUP_FILE = os.environ.get("STATE_BACKUP_FILE", os.path.join(os.path.dirname(os.path.realpath(__file__)), "state.backup.json"))
VALIDATOR_SCRIPT_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)), "validator.py")
HEALTH_CHECK_CRON = os.environ.get("HEALTH_CHECK_CRON", "*/5 * * * *")
FAILURES_TO_DISABLE = int(os.environ.get("FAILURES_TO_DISABLE", 2))
CONCURRENT_CHECKS = int(os.environ.get("CONCURRENT_CHECKS", 5))
MIN_CYCLE_SECONDS = 5
VENV_PYTHON = os.environ.get("VENV_PYTHON", os.path.join(os.path.dirname(os.path.realpath(__file__)), '.venv', 'bin', 'python3'))
HEALTH_CHECK_LOG_FILE = os.environ.get("HEALTH_CHECK_LOG_FILE", "/var/log/realm_health_check.log")
MAX_LOG_SIZE_MB = 5


def log(message, level="INFO"):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level.upper()}] {message}", flush=True)

def handle_log_rotation():
    """Checks log file size and rotates if it exceeds the limit."""
    if not os.path.exists(HEALTH_CHECK_LOG_FILE):
        return
    
    try:
        file_size_mb = os.path.getsize(HEALTH_CHECK_LOG_FILE) / (1024 * 1024)
        
        if file_size_mb > MAX_LOG_SIZE_MB:
            log(f"Log file size ({file_size_mb:.2f} MB) exceeds limit of {MAX_LOG_SIZE_MB} MB. Rotating log.", "WARN")
            backup_path = HEALTH_CHECK_LOG_FILE + ".bak"
            if os.path.exists(backup_path):
                os.remove(backup_path)
            os.rename(HEALTH_CHECK_LOG_FILE, backup_path)
            log("Log file rotated. New log file created.", "INFO")
    except Exception as e:
        log(f"Error during log rotation: {e}", "ERROR")


def load_json_file(file_path, default=None):
    if default is None:
        default = {}
    if not os.path.exists(file_path):
        return default
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
            return json.loads(content, object_pairs_hook=OrderedDict) if content else default
    except (json.JSONDecodeError, FileNotFoundError):
        return default

def save_json_file(data, file_path):
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
    except IOError as e:
        log(f"Error saving state file to {file_path}: {e}", "ERROR")

def parse_toml(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except FileNotFoundError:
        return None

    data = OrderedDict()
    data['endpoints'] = []
    current_section = None
    in_endpoint_block = False

    for line in lines:
        stripped_line = line.strip()
        if not stripped_line or stripped_line.startswith('#'):
            continue

        if stripped_line == '[[endpoints]]':
            current_section = OrderedDict()
            data['endpoints'].append(current_section)
            in_endpoint_block = True
            continue
        
        section_match = re.match(r'^\[([^\]]+)\]', stripped_line)
        if section_match and not in_endpoint_block:
            current_section_name = section_match.group(1)
            data.setdefault(current_section_name, OrderedDict())
            current_section = data[current_section_name]
            continue
            
        if current_section is None:
            current_section = data

        match = re.match(r'^\s*([\w\.]+)\s*=\s*(.*)', stripped_line)
        if not match: continue
        key, value_str = match.groups()
        
        value = None
        if value_str.startswith('"'):
            value = value_str.strip('"')
        elif value_str.startswith('['):
            value = [v.strip().strip('"') for v in re.findall(r'"([^"]+)"', value_str)]
        else:
            if value_str.lower() in ['true', 'false']:
                value = value_str.lower() == 'true'
            elif re.match(r'^-?\d+$', value_str):
                value = int(value_str)
        
        if value is not None:
            current_section[key] = value
            
    return data

def serialize_to_toml(data):
    output_lines = []
    
    global_keys = [k for k in data if k != 'endpoints']
    for key in global_keys:
        section = data[key]
        if isinstance(section, dict) and section:
             output_lines.append(f"[{key}]")
             for sub_key, value in section.items():
                 if isinstance(value, str):
                     output_lines.append(f'  {sub_key} = "{value}"')
                 elif isinstance(value, bool):
                     output_lines.append(f'  {sub_key} = {str(value).lower()}')
                 elif isinstance(value, list):
                     formatted_values = ", ".join([f'"{v}"' for v in value])
                     output_lines.append(f'  {sub_key} = [{formatted_values}]')
                 else:
                     output_lines.append(f'  {sub_key} = {value}')
             output_lines.append("")

    for endpoint in data.get('endpoints', []):
        output_lines.append("[[endpoints]]")
        
        if 'listen' in endpoint: output_lines.append(f'  listen = "{endpoint["listen"]}"')
        if 'remote' in endpoint: output_lines.append(f'  remote = "{endpoint["remote"]}"')
        
        for key, value in endpoint.items():
            if key in ['listen', 'remote']: continue
            if isinstance(value, str):
                output_lines.append(f'  {key} = "{value}"')
            elif isinstance(value, list):
                formatted_values = ", ".join([f'"{v}"' for v in value])
                output_lines.append(f'  {key} = [{formatted_values}]')
        output_lines.append("")

    return "\n".join(output_lines)

def run_check(script_path, host, port, timeout):
    """Executes a single health check script."""
    try:
        process = subprocess.run(
            ["timeout", str(timeout), script_path, host, str(port)],
            capture_output=True, text=True, check=False
        )
        return process.returncode
    except Exception as e:
        log(f"Failed to execute check script {script_path}: {e}", "ERROR")
        return 1

def modify_config_logic(config_data, state_data, action, address):
    config_changed = False
    
    if action == "enable":
        if address not in state_data:
            return config_data, state_data, False

        log(f"Restoring configuration for recovered upstream: '{address}'", "INFO")
        
        blocks_to_restore_info = state_data[address]
        listen_addrs_to_process = {info['listen'] for info in blocks_to_restore_info}
        
        config_data['endpoints'] = [ep for ep in config_data.get('endpoints', []) if ep.get('listen') not in listen_addrs_to_process]
        
        for info in blocks_to_restore_info:
            restored_endpoint = json.loads(info['original_block'], object_pairs_hook=OrderedDict)
            config_data['endpoints'].append(restored_endpoint)
        
        del state_data[address]
        config_changed = True

    elif action == "disable":
        indices_to_process = []
        for i, endpoint in enumerate(config_data.get('endpoints', [])):
            remotes = ([endpoint.get('remote')] if 'remote' in endpoint else []) + endpoint.get('extra_remotes', [])
            if address in remotes:
                indices_to_process.append(i)
        
        if not indices_to_process:
            return config_data, state_data, False

        for i in sorted(indices_to_process, reverse=True):
            target_endpoint = config_data['endpoints'][i]
            listen_addr = target_endpoint.get("listen")

            if not listen_addr: continue
            
            backup_list = state_data.get(address, [])
            if not any(item['listen'] == listen_addr for item in backup_list):
                 backup_list.append({
                    "listen": listen_addr,
                    "original_block": json.dumps(target_endpoint)
                })
            state_data[address] = backup_list
            
            original_remote = target_endpoint.get('remote', "")
            extra_remotes = target_endpoint.get('extra_remotes', [])
            full_remotes_list = ([original_remote] if original_remote else []) + extra_remotes
            
            weights, strategy = [], "roundrobin"
            if 'balance' in target_endpoint:
                balance_match = re.search(r'"?([^:]+):\s*([^"]+)"?', target_endpoint['balance'])
                if balance_match:
                    strategy = balance_match.group(1).strip()
                    weights = [w.strip() for w in balance_match.group(2).split(',')]

            if weights and len(weights) != len(full_remotes_list):
                log(f"Error: 权重数量({len(weights)})与节点数量({len(full_remotes_list)})不匹配，跳过此块。", "ERROR")
                continue

            if len(full_remotes_list) <= 1:
                log(f"规则 '{listen_addr}' 中唯一的上游 '{address}' 失效，将移除整个规则。", "WARN")
                config_data['endpoints'].pop(i)
            else:
                failed_index = full_remotes_list.index(address)
                full_remotes_list.pop(failed_index)
                if weights and failed_index < len(weights):
                    weights.pop(failed_index)
                
                target_endpoint['remote'] = full_remotes_list.pop(0)
                if full_remotes_list:
                    target_endpoint['extra_remotes'] = full_remotes_list
                elif 'extra_remotes' in target_endpoint:
                    del target_endpoint['extra_remotes']

                if full_remotes_list and weights:
                    target_endpoint['balance'] = f"{strategy}: {', '.join(weights)}"
                elif 'balance' in target_endpoint:
                    del target_endpoint['balance']
            
            config_changed = True

    return config_data, state_data, config_changed

def perform_modification(config_file, action, address, state_file):
    config_data = parse_toml(config_file)
    if not config_data:
        log(f"无法解析配置文件: {config_file}", "ERROR")
        return False
    
    state_data = load_json_file(state_file)
    
    config_data, state_data, modified = modify_config_logic(config_data, state_data, action, address)

    if modified:
        log(f"配置已更新 (操作: {action}, 地址: {address})。正在写回文件...")
        new_toml_content = serialize_to_toml(config_data)
        with open(config_file, 'w', encoding='utf-8') as f:
            f.write(new_toml_content)
        save_json_file(state_data, state_file)
        return True
    else:
        return False

def parse_and_print_upstreams(config_file):
    config_data = parse_toml(config_file)
    if not config_data:
        sys.exit(1)
    
    upstreams = set()
    for endpoint in config_data.get('endpoints', []):
        if endpoint.get('remote'):
            upstreams.add(endpoint['remote'])
        upstreams.update(endpoint.get('extra_remotes', []))

    for upstream in sorted(list(upstreams)):
        print(upstream)

def health_check_daemon():
    """Main daemon loop for concurrent health checks."""
    effective_cron = HEALTH_CHECK_CRON
    log(f"Health check daemon starting with schedule: '{effective_cron}'")
    
    try:
        base_iter = croniter(effective_cron, datetime.now())
    except ValueError as e:
        log(f"Invalid cron format '{effective_cron}': {e}. Exiting.", "ERROR")
        sys.exit(1)

    first_run_time = base_iter.get_next(datetime)
    second_run_time = base_iter.get_next(datetime)
    
    total_cycle_seconds = (second_run_time - first_run_time).total_seconds()
    
    if total_cycle_seconds < MIN_CYCLE_SECONDS:
        log(f"Cron schedule '{effective_cron}' results in a period shorter than {MIN_CYCLE_SECONDS}s.", "WARN")
        total_cycle_seconds = MIN_CYCLE_SECONDS
        log(f"Period has been automatically adjusted to {MIN_CYCLE_SECONDS} seconds.", "WARN")

    dynamic_timeout = max(1, int(total_cycle_seconds / 2))
    log(f"Cycle interval set to {total_cycle_seconds}s. Health check timeout set to {dynamic_timeout}s.")

    failure_counts = {}
    cron = croniter(effective_cron, datetime.now())

    while True:
        try:
            handle_log_rotation()
            
            next_run_time = cron.get_next(datetime)
            
            sleep_duration = (next_run_time - datetime.now()).total_seconds()
            if sleep_duration > 0:
                log(f"Sleeping for {int(sleep_duration)} seconds until next cycle at {next_run_time.strftime('%H:%M:%S')}.")
                time.sleep(sleep_duration)
            
            log(f"--- New Check Cycle --- (Concurrency: {CONCURRENT_CHECKS}, Timeout: {dynamic_timeout}s)")
            
            if not os.path.exists(HEALTH_CHECKS_FILE):
                log("Health checks file not found. Skipping cycle.", "WARN")
                continue

            with open(HEALTH_CHECKS_FILE, 'r', encoding='utf-8') as f:
                tasks_to_run = [line.strip() for line in f if line.strip() and not line.startswith('#')]
            
            if not tasks_to_run:
                log("No health checks configured. Skipping cycle.")
                continue

            check_results = []
            with ThreadPoolExecutor(max_workers=CONCURRENT_CHECKS) as executor:
                future_to_task = {}
                for task_line in tasks_to_run:
                    upstream_addr, script_path = task_line.split('=', 1)
                    host, port = "", ""
                    match = re.match(r'^\[(.+)\]:(.+)$', upstream_addr) or re.match(r'^([^:]+):([^:]+)$', upstream_addr)
                    if match: host, port = match.groups()
                    else: host = upstream_addr
                    
                    future = executor.submit(run_check, script_path, host, str(port), dynamic_timeout)
                    future_to_task[future] = upstream_addr

                for future in as_completed(future_to_task):
                    upstream_addr = future_to_task[future]
                    try:
                        exit_code = future.result()
                        check_results.append({'address': upstream_addr, 'exit_code': exit_code})
                    except Exception as exc:
                        log(f"Task for '{upstream_addr}' generated an exception: {exc}", "ERROR")
                        check_results.append({'address': upstream_addr, 'exit_code': 1})
            
            success_count = sum(1 for r in check_results if r['exit_code'] == 0)
            fail_count = len(check_results) - success_count
            log(f"Check cycle summary: {len(check_results)} total, {success_count} successful, {fail_count} failed.")

            upstreams_to_disable = set()
            upstreams_to_enable = set()
            state_data = load_json_file(STATE_BACKUP_FILE)
            
            current_config_data = parse_toml(REALM_CONFIG_FILE)
            if not current_config_data:
                log("Could not parse main config, skipping result processing.", "ERROR")
                continue
                
            active_upstreams = {ep.get('remote') for ep in current_config_data.get('endpoints', []) if ep.get('remote')}
            for ep in current_config_data.get('endpoints', []):
                active_upstreams.update(ep.get('extra_remotes', []))

            for result in check_results:
                address = result['address']
                exit_code = result['exit_code']

                if exit_code == 0:
                    if failure_counts.get(address, 0) > 0:
                        log(f"Upstream '{address}' has RECOVERED.", "INFO")
                    failure_counts[address] = 0
                    if address in state_data:
                        upstreams_to_enable.add(address)
                else:
                    failure_counts[address] = failure_counts.get(address, 0) + 1
                    log(f"Upstream '{address}' FAILED check (Exit code: {exit_code}, Failures: {failure_counts[address]}).", "WARN")
                    if failure_counts[address] >= FAILURES_TO_DISABLE and address in active_upstreams:
                        upstreams_to_disable.add(address)

            if upstreams_to_disable or upstreams_to_enable:
                log("Applying configuration changes...", "INFO")
                config_data = parse_toml(REALM_CONFIG_FILE)
                if not config_data:
                    log("Failed to read config file for modification. Aborting update.", "ERROR")
                    continue
                
                state_data = load_json_file(STATE_BACKUP_FILE)
                config_modified = False

                for addr in upstreams_to_enable:
                    config_data, state_data, changed = modify_config_logic(config_data, state_data, 'enable', addr)
                    if changed: config_modified = True

                for addr in upstreams_to_disable:
                    config_data, state_data, changed = modify_config_logic(config_data, state_data, 'disable', addr)
                    if changed: config_modified = True
                
                if config_modified:
                    log("Saving modified configuration and state files...")
                    new_toml_content = serialize_to_toml(config_data)
                    with open(REALM_CONFIG_FILE, 'w', encoding='utf-8') as f:
                        f.write(new_toml_content)
                    save_json_file(state_data, STATE_BACKUP_FILE)
                    
                    log("Validating new configuration...")
                    validation_process = subprocess.run([VENV_PYTHON, VALIDATOR_SCRIPT_PATH, "--file", REALM_CONFIG_FILE])
                    if validation_process.returncode == 0:
                        log("Validation successful. Restarting realm service...", "INFO")
                        subprocess.run(["systemctl", "restart", "realm"])
                    else:
                        log("Validation FAILED! Realm service not restarted. Please check config manually.", "ERROR")
                else:
                    log("No effective configuration changes were made after processing results.")
            else:
                 log("All checks passed or no action required.")


        except Exception as e:
            log(f"An unexpected error occurred in the daemon loop: {e}", "ERROR")
            time.sleep(60)

def main():
    parser = argparse.ArgumentParser(description="Realm Health Checker and Tools.")
    parser.add_argument("--action", required=True, choices=["start_daemon", "disable", "enable", "parse_upstreams", "validate"], help="Action to perform.")
    parser.add_argument("--file", help="Path to the realm config file.")
    parser.add_argument("--address", help="The upstream address to act upon for disable/enable actions.")
    parser.add_argument("--state-file", help="Path to the state backup JSON file.")
    
    args = parser.parse_args()

    if args.action == "start_daemon":
        health_check_daemon()
    elif args.action in ["disable", "enable"]:
        if not all([args.file, args.address, args.state_file]):
            sys.exit(1)
        perform_modification(args.file, args.action, args.address, args.state_file)
    elif args.action == "parse_upstreams":
        if not args.file:
            sys.exit(1)
        parse_and_print_upstreams(args.file)

if __name__ == "__main__":
    main()
