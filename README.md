# Realm 管理脚本 / Realm Management Script

## English

### Overview

This project provides a comprehensive suite of scripts for managing the `realm` port forwarding tool, with a strong focus on high availability and automated failover. It includes a user-friendly management interface and a background daemon that monitors upstream servers, dynamically updating the `realm` configuration to ensure service continuity.


### Key Features

* **Automated Dependency Management**: Automatically checks for and installs required system commands and Python packages.
* **Isolated Python Environment**: Uses a local Python virtual environment (`.venv`) to avoid modifying the host system's packages.
* **Automated Failover**: The daemon monitors upstream endpoints and automatically removes failing nodes from the active configuration.
* **Automatic Recovery**: Automatically restores nodes to the configuration once they become healthy again.
* **Concurrent Health Checks**: Utilizes a thread pool to perform health checks in parallel for efficiency.
* **Flexible Scheduling**: Configure health check frequency using standard Cron expressions (minimum 5-second interval).
* **Interactive Management**: A full-featured, menu-driven interface for easy management of all services and configurations.
* **Log Rotation**: Automatically rotates the health check log file to prevent it from growing indefinitely.

### Prerequisites

* A Linux system (Debian/Ubuntu or RHEL/CentOS based).
* `sudo` or `root` privileges.
* `Python 3.6` or higher. The script will attempt to install it if missing.

### How to Use

1.  Ensure all script files are in the same directory.
2.  Grant execution permission to the main script: `chmod +x realm_management.sh`
3.  Run the script with `sudo`:

    ```bash
    sudo ./realm_management.sh
    ```
4.  Follow the on-screen menu options to install, configure, and manage your `realm` service.

---

## 中文说明

### 项目简介

本项目提供了一套完整的 `realm` 端口转发工具管理脚本，专注于实现高可用性和自动化故障转移。它包含一个用户友好的管理界面和一个后台守护进程，该进程能够监控上游服务器的健康状况，并动态更新 `realm` 配置以保证服务的连续性。


### 核心功能

* **自动化依赖管理**: 自动检查并提示安装所需的系统命令和 Python 包。
* **隔离的Python环境**: 使用本地的 Python 虚拟环境（`.venv`），避免污染宿主机的全局包。
* **自动故障转移**: 守护进程监控上游端点，并自动从活动配置中移除故障节点。
* **自动恢复**: 一旦节点恢复健康，会自动将其重新加入到配置中。
* **并发健康检查**: 使用线程池并行执行健康检查，以提高效率。
* **灵活的调度**: 使用标准的 Cron 表达式来配置健康检查的频率（最小间隔为5秒）。
* **交互式管理**: 功能齐全的菜单驱动界面，便于管理所有服务和配置。
* **日志滚动**: 自动对健康检查日志文件进行滚动，防止其无限增大。

### 运行前提

* 基于 Debian/Ubuntu 或 RHEL/CentOS 的 Linux 系统。
* `sudo` 或 `root` 权限。
* `Python 3.6` 或更高版本。如果缺失，脚本会尝试引导您进行安装。

### 如何使用

1.  确保所有脚本文件都位于同一个目录下。
2.  授予主脚本执行权限: `chmod +x realm_management.sh`
3.  使用 `sudo` 运行脚本：

    ```bash
    sudo ./realm_management.sh
    ```
4.  根据屏幕上的菜单选项来安装、配置和管理您的 `realm` 服务。
