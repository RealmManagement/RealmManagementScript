
import sys
import re
import json
import argparse
import os
from collections import OrderedDict
import difflib

KEY_TYPES = {
    'level': 'string', 'output': 'string',
    'mode': 'string', 'protocol': 'string', 'nameservers': 'array',
    'min_ttl': 'uint', 'max_ttl': 'uint', 'cache_size': 'uint',
    'no_tcp': 'bool', 'use_udp': 'bool', 'ipv6_only': 'bool',
    'tcp_timeout': 'uint', 'udp_timeout': 'uint',
    'tcp_keepalive': 'uint', 'tcp_keepalive_probe': 'uint',
    'send_proxy': 'bool', 'send_proxy_version': 'uint',
    'accept_proxy': 'bool', 'accept_proxy_timeout': 'uint',
    'listen': 'string', 'remote': 'string', 'extra_remotes': 'array',
    'balance': 'string', 'through': 'string', 'interface': 'string',
    'listen_interface': 'string', 'listen_transport': 'string',
    'remote_transport': 'string', 'network': 'object'
}

KNOWN_NORMAL_SECTIONS = ["log", "dns", "network"]
KNOWN_ARRAY_SECTIONS = ["endpoints"]
KNOWN_SECTIONS = KNOWN_NORMAL_SECTIONS + KNOWN_ARRAY_SECTIONS

KNOWN_KEYS_IN_SECTION = {
    "log": ["level", "output"],
    "dns": ["mode", "protocol", "nameservers", "min_ttl", "max_ttl", "cache_size"],
    "network": [
        "no_tcp", "use_udp", "ipv6_only", "tcp_timeout", "udp_timeout", 
        "tcp_keepalive", "tcp_keepalive_probe", "send_proxy", 
        "send_proxy_version", "accept_proxy", "accept_proxy_timeout"
    ],
    "endpoints": [
        "listen", "remote", "extra_remotes", "balance", "through", 
        "interface", "listen_interface", "listen_transport", 
        "remote_transport", "network"
    ]
}

def log_error(message, indent=5):
    """打印标准格式的错误信息到 stderr"""
    print(f"{' ' * indent}\033[0;31m[错误] {message}\033[0m", file=sys.stderr, flush=True)

def log_warn(message, indent=5):
    """打印标准格式的警告信息到 stderr"""
    print(f"{' ' * indent}\033[0;33m[警告] {message}\033[0m", file=sys.stderr, flush=True)

def log_info(message, indent=0):
    """打印标准格式的普通信息到 stderr"""
    print(f"{' ' * indent}\033[0;36m[信息]\033[0m {message}", file=sys.stderr, flush=True)

def _correct_key(key, valid_keys, context_msg):
    """一个内部辅助函数，用于校正单个键。"""
    if key in valid_keys:
        return key
    matches = difflib.get_close_matches(key, valid_keys, n=1, cutoff=0.7)
    if len(matches) == 1:
        corrected_key = matches[0]
        log_warn(f"配置项 '{key}' 不标准, {context_msg}已自动校正为 '{corrected_key}'。")
        return corrected_key
    log_error(f"无法识别的配置项 '{key}' {context_msg}。")
    if valid_keys:
        log_error(f"    -> 此处有效的配置项为: {valid_keys}")
    return None

def parse_and_validate_value(value_str, expected_type, context_msg):
    """
    根据期望的类型解析和校验值。
    不再推断类型，而是强制校验。
    """
    value_str = value_str.strip()
    
    if expected_type == 'bool':
        if value_str.lower() == 'true': return True
        if value_str.lower() == 'false': return False
        log_error(f"类型错误 {context_msg}: 值 '{value_str}' 不是一个有效的布尔值 (应为 true 或 false)。")
        return None

    if expected_type == 'uint':
        if value_str.isdigit(): return int(value_str)
        log_error(f"类型错误 {context_msg}: 值 '{value_str}' 不是一个有效的无符号整数。")
        return None

    if expected_type == 'array':
        if value_str.startswith('[') and value_str.endswith(']'):
            return [v.strip().strip('"') for v in re.findall(r'"([^"]+)"', value_str)]
        log_error(f"类型错误 {context_msg}: 值 '{value_str}' 不是一个有效的数组格式 (应为 [\"a\", \"b\"])。")
        return None

    if expected_type == 'string':
        if value_str.startswith('"') and value_str.endswith('"'):
            return value_str[1:-1]
        log_error(f"类型错误 {context_msg}: 值 '{value_str}' 不是一个有效的字符串 (应由双引号包裹)。")
        return None
    
    log_error(f"内部脚本错误: 未知的期望类型 '{expected_type}'。")
    return None

def correct_json_data(data):
    """递归地校正并校验从JSON文件解析出的字典的键和值类型。"""
    if not isinstance(data, dict): return None

    corrected_data = OrderedDict()
    for section_name, section_value in data.items():
        corrected_section_name = section_name
        if section_name not in KNOWN_SECTIONS:
            matches = difflib.get_close_matches(section_name, KNOWN_SECTIONS, n=1, cutoff=0.6)
            if len(matches) == 1:
                corrected_section_name = matches[0]
                log_warn(f"配置节 '{section_name}' 不标准, 已自动校正为 '{corrected_section_name}'。")
            else:
                log_error(f"无法识别的顶层配置节 '{section_name}'。"); return None
        corrected_data[corrected_section_name] = section_value

    final_data = OrderedDict()
    for section_name, section_value in corrected_data.items():
        context_msg = f"在节 '[{section_name}]' 中, "
        
        if section_name in KNOWN_NORMAL_SECTIONS:
            if not isinstance(section_value, dict):
                log_error(f"节 '{section_name}' 的值应为一个对象, 但实际为 {type(section_value).__name__}。"); return None
            
            corrected_section_dict = OrderedDict()
            valid_keys = KNOWN_KEYS_IN_SECTION[section_name]
            for key, value in section_value.items():
                corrected_key = _correct_key(key, valid_keys, context_msg)
                if corrected_key is None: return None
                expected_type = KEY_TYPES.get(corrected_key)
                if expected_type == 'uint' and isinstance(value, int) and value >= 0:
                    pass # ok
                elif expected_type == 'bool' and isinstance(value, bool):
                    pass # ok
                elif expected_type == 'string' and isinstance(value, str):
                    pass # ok
                elif expected_type == 'array' and isinstance(value, list):
                    pass # ok
                else:
                    log_error(f"类型错误 {context_msg}: 配置项 '{corrected_key}' 的值 '{value}' 类型不正确，应为 {expected_type}。"); return None
                corrected_section_dict[corrected_key] = value
            final_data[section_name] = corrected_section_dict

        elif section_name in KNOWN_ARRAY_SECTIONS:
            if not isinstance(section_value, list):
                log_error(f"节 '{section_name}' 的值应为一个数组, 但实际为 {type(section_value).__name__}。"); return None

            corrected_list = []
            valid_keys = KNOWN_KEYS_IN_SECTION[section_name]
            for i, item_dict in enumerate(section_value, 1):
                corrected_item_dict = OrderedDict()
                item_context_msg = f"在第 {i} 个 '{section_name}' 项目中, "
                for key, value in item_dict.items():
                    corrected_key = _correct_key(key, valid_keys, item_context_msg)
                    if corrected_key is None: return None
                    expected_type = KEY_TYPES.get(corrected_key)
                    corrected_item_dict[corrected_key] = value
                corrected_list.append(corrected_item_dict)
            final_data[section_name] = corrected_list
    return final_data


def parse_toml(lines):
    """一个增强的TOML解析器，支持自动校正不完整的节(section)和项(key)名称。"""
    data = OrderedDict({'endpoints': []})
    current_section_dict = None
    current_section_name = ""
    
    for line_num, line in enumerate(lines, 1):
        original_line = line.strip()
        if not original_line or original_line.startswith('#'): continue

        array_match = re.match(r'^\[\[\s*([^\[\]]+)\s*\]\]$', original_line)
        normal_match = re.match(r'^\[\s*([^\[\]]+)\s*\]$', original_line)
        
        if array_match:
            section_name = array_match.group(1).strip()
            if section_name not in KNOWN_ARRAY_SECTIONS:
                matches = difflib.get_close_matches(section_name, KNOWN_ARRAY_SECTIONS, n=1, cutoff=0.7)
                if len(matches) == 1:
                    section_name = matches[0]
                    log_warn(f"在第 {line_num} 行: 配置节 '[[{array_match.group(1).strip()}]]' 不标准, 已自动校正为 '[[{section_name}]]'。")
                else:
                    log_error(f"在第 {line_num} 行: 无法识别的数组配置节 '[[{section_name}]]'。"); return None
            
            if section_name == "endpoints":
                endpoint_dict = OrderedDict()
                data['endpoints'].append(endpoint_dict)
                current_section_dict = endpoint_dict
                current_section_name = "endpoints"

        elif normal_match:
            section_name = normal_match.group(1).strip()
            if section_name not in KNOWN_NORMAL_SECTIONS:
                matches = difflib.get_close_matches(section_name, KNOWN_NORMAL_SECTIONS, n=1, cutoff=0.6)
                if len(matches) == 1:
                    section_name = matches[0]
                    log_warn(f"在第 {line_num} 行: 配置节 '[{normal_match.group(1).strip()}]' 不标准, 已自动校正为 '[{section_name}]'。")
                else:
                    log_error(f"在第 {line_num} 行: 无法识别的配置节 '[{section_name}]'。"); return None
            
            if section_name not in data: data[section_name] = OrderedDict()
            current_section_dict = data[section_name]
            current_section_name = section_name
            
        elif current_section_dict is not None and '=' in original_line:
            kv_match = re.match(r'^\s*([\w\.]+)\s*=\s*(.*)', original_line)
            if kv_match:
                key, value_str = kv_match.groups()
                valid_keys = KNOWN_KEYS_IN_SECTION.get(current_section_name, [])
                context_msg = f"在节 '[{current_section_name}]' 中, "
                key = _correct_key(key, valid_keys, context_msg)
                if key is None: return None
                
                value_str_no_comment = value_str.split('#', 1)[0].strip()
                expected_type = KEY_TYPES.get(key)
                if not expected_type:
                    log_error(f"内部脚本错误: 配置项 '{key}' 未定义类型。")
                    return None

                parsed_value = parse_and_validate_value(value_str_no_comment, expected_type, context_msg)
                if parsed_value is None: return None # 如果值校验失败，则中断
                
                current_section_dict[key] = parsed_value
            else:
                 log_error(f"在第 {line_num} 行: 发现无效的键值对格式: '{original_line}'。"); return None
        
        else:
            log_error(f"在第 {line_num} 行: 发现无法解析的无效行: '{original_line}'。"); return None

    return data


def serialize_to_toml(data):
    """将校正后的数据对象序列化为 TOML 格式的字符串。"""
    output_lines = []
    
    for section_name in KNOWN_NORMAL_SECTIONS:
        if section_name in data:
            output_lines.append(f"[{section_name}]")
            for key, value in data[section_name].items():
                if isinstance(value, bool):
                    output_lines.append(f'{key} = {str(value).lower()}')
                elif isinstance(value, int):
                    output_lines.append(f'{key} = {value}')
                elif isinstance(value, list):
                    formatted_values = ", ".join([f'"{v}"' for v in value])
                    output_lines.append(f'{key} = [{formatted_values}]')
                else:
                    output_lines.append(f'{key} = "{value}"')
            output_lines.append("")

    if 'endpoints' in data and data['endpoints']:
        for endpoint in data['endpoints']:
            output_lines.append("[[endpoints]]")
            for key, value in endpoint.items():
                if isinstance(value, bool): output_lines.append(f'  {key} = {str(value).lower()}')
                elif isinstance(value, int): output_lines.append(f'  {key} = {value}')
                elif isinstance(value, list):
                    formatted_values = ", ".join([f'"{v}"' for v in value])
                    output_lines.append(f'  {key} = [{formatted_values}]')
                else: output_lines.append(f'  {key} = "{value}"')
            output_lines.append("")

    return "\n".join(output_lines)


def validate_config(file_path):
    """主校验函数，现在返回一个元组 (is_valid, corrected_data)。"""
    log_info(f"开始检查配置文件: {file_path}")

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            if file_path.endswith('.json'):
                raw_data = json.load(f, object_pairs_hook=OrderedDict)
                data = correct_json_data(raw_data)
            elif file_path.endswith('.toml'):
                lines = f.readlines()
                data = parse_toml(lines)
            else:
                log_error(f"不支持的文件类型: {file_path}"); return False, None
        
        if data is None: return False, None
        if not data:
            log_error("配置文件内容为空或无法解析出有效配置。"); return False, None
            
    except Exception as e:
        log_error(f"文件读取或解析失败: {e}"); return False, None

    is_struct_valid = True
    endpoints = data.get('endpoints', [])
    if not endpoints:
        log_error("配置文件中必须至少包含一个 'endpoints' 配置块。"); is_struct_valid = False

    seen_listen_ports = set()
    for i, endpoint in enumerate(endpoints, 1):
        if not isinstance(endpoint, dict):
            log_error(f"第 {i} 个 endpoint 项目应为一个对象，但格式不正确。"); is_struct_valid = False; continue
        if not endpoint.get('listen'):
            log_error(f"第 {i} 个 endpoint 缺少 'listen' 字段。"); is_struct_valid = False
        if not endpoint.get('remote'):
            log_error(f"第 {i} 个 endpoint 缺少 'remote' 字段。"); is_struct_valid = False

        listen_addr = endpoint.get('listen')
        if listen_addr:
            if listen_addr in seen_listen_ports:
                log_error(f"第 {i} 个 endpoint 的 listen 地址 '{listen_addr}' 与之前的配置重复。"); is_struct_valid = False
            else:
                seen_listen_ports.add(listen_addr)
    
    return is_struct_valid, data


def main():
    parser = argparse.ArgumentParser(description="校验 Realm 配置文件，并可选择输出自动修复后的版本。", formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--file", required=True, help="需要校验的 Realm 配置文件路径 (.toml 或 .json)。")
    parser.add_argument('--autofix', action='store_true', help="如果设置此标志，当配置文件有效(或可被成功自动校正)时，\n会将格式化且校正后的配置内容输出到标准输出(stdout)。\n所有校验信息(INFO, WARN, ERROR)将输出到标准错误(stderr)。")
    args = parser.parse_args()

    if not os.path.exists(args.file):
        log_error(f"配置文件未找到: {args.file}"); sys.exit(1)

    is_valid, corrected_data = validate_config(args.file)

    if is_valid:
        log_info("所有检查项均符合规范。")
        if args.autofix:
            if args.file.endswith('.json'):
                print(json.dumps(corrected_data, indent=2, ensure_ascii=False))
            elif args.file.endswith('.toml'):
                print(serialize_to_toml(corrected_data))
        sys.exit(0)
    else:
        log_error("配置文件存在无法自动修复的错误。"); sys.exit(1)

if __name__ == "__main__":
    main()
