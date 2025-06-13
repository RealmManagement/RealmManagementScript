
import sys
import re
import json
import argparse
import os
from collections import OrderedDict

def log_error(message, indent=5):
    """打印标准格式的错误信息"""
    print(f"{' ' * indent}\033[0;31m[错误] {message}\033[0m", flush=True)

def parse_toml(lines):
    """一个简化的TOML解析器，只提取endpoints用于验证"""
    data = {'endpoints': []}
    current_endpoint = None
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line == '[[endpoints]]':
            current_endpoint = {}
            data['endpoints'].append(current_endpoint)
            continue
        if current_endpoint is not None:
            match = re.match(r'^\s*(\w+)\s*=\s*(.*)', line)
            if not match: continue
            key, value_str = match.groups()
            
            if key in ["listen", "remote", "balance"]:
                current_endpoint[key] = value_str.strip('"')
            elif key == "extra_remotes":
                current_endpoint[key] = [v.strip().strip('"') for v in re.findall(r'"([^"]+)"', value_str)]
    return data

def validate_config(file_path):
    """验证配置文件是否符合规范"""
    is_valid = True
    print(f"开始检查配置文件: {file_path}")

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        if not content.strip():
            log_error("配置文件为空，必须至少包含一个 [[endpoints]] 配置块。")
            return False

        if file_path.endswith('.json'):
            data = json.loads(content)
        elif file_path.endswith('.toml'):
            data = parse_toml(content.splitlines())
        else:
            log_error(f"不支持的文件类型: {file_path}")
            return False
            
    except Exception as e:
        log_error(f"文件读取或解析失败: {e}")
        return False

    endpoints = data.get('endpoints', [])
    if not endpoints:
        log_error("配置文件中必须至少包含一个 [[endpoints]] 配置块。")
        return False

    seen_listen_ports = set()
    for i, endpoint in enumerate(endpoints, 1):
        print(f"  -> 正在检查第 {i} 个 endpoint...")
        
        listen_addr = endpoint.get('listen')
        if not listen_addr:
            log_error(f"第 {i} 个 endpoint 缺少 'listen' 字段。")
            is_valid = False
        if 'remote' not in endpoint or not endpoint['remote']:
            log_error(f"第 {i} 个 endpoint 缺少 'remote' 字段。")
            is_valid = False

        if listen_addr:
            if listen_addr in seen_listen_ports:
                log_error(f"第 {i} 个 endpoint 的 listen 地址 '{listen_addr}' 与之前的配置重复。")
                is_valid = False
            else:
                seen_listen_ports.add(listen_addr)

        if 'balance' in endpoint:
            remotes_count = 1 + len(endpoint.get('extra_remotes', []))
            balance_match = re.search(r':\s*(.*)', endpoint['balance'])
            if balance_match:
                weights_str = balance_match.group(1).strip()
                weights = [w.strip() for w in weights_str.split(',') if w.strip()]
                if len(weights) != remotes_count:
                    log_error(f"第 {i} 个 endpoint 的 balance 权重数量 ({len(weights)}) 与节点数量 ({remotes_count}) 不匹配。")
                    is_valid = False
            else:
                log_error(f"第 {i} 个 endpoint 的 balance 格式不正确。")
                is_valid = False
    
    return is_valid

def main():
    parser = argparse.ArgumentParser(description="Validate realm config file.")
    parser.add_argument("--file", required=True, help="Path to the realm config file (.toml or .json).")
    args = parser.parse_args()

    if not os.path.exists(args.file):
        print(f"Error: Config file not found at {args.file}", file=sys.stderr)
        sys.exit(1)

    if validate_config(args.file):
        print("  -> \033[0;32m[通过] 所有检查项均符合规范。\033[0m")
        sys.exit(0)
    else:
        sys.exit(1)

if __name__ == "__main__":
    main()