#!/bin/bash
# pve-manager-status.sh
# Last Modified: 2025-10-28

echo -e "\n🛠️ \033[1;33;41mPVE-Manager-Status v0.6.0 by Sagittarius\033[0m"

echo -e "为你的 ProxmoxVE 节点概要页面添加扩展的硬件监控信息"
echo -e "OpenSource on GitHub (https://github.com/Sagittarius/PVE-Manager-Status)\n"

# 先决条件执行判断
# 执行用户判断, 必须为 root 用户执行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ 请以 root 身份运行此脚本!"
    echo && exit 1
fi

# 执行环境判断, 必须为 Debian 发行版且存在 ProxmoxVE 环境
if ! command -v pveversion &> /dev/null; then
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
            echo -e "⛔ 检测到当前系统非 Debian 发行版, 停止执行!"
            echo && exit 1
        fi
    fi
    echo -e "⛔ 未检测到 ProxmoxVE 环境, 停止执行!"
    echo && exit 1
fi

read -p "确认执行吗? [y/N]:" para

# 脚本执行前确认
[[ "$para" =~ ^[Yy]$ ]] || { [[ "$para" =~ ^[Nn]$ ]] && echo -e "\n🚫 操作取消, 未执行任何操作!" && exit 0; echo -e "\n⚠️ 无效输入, 未执行任何操作!"; exit 1; }

nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
pvever=$(pveversion | awk -F"/" '{print $2}')
NODE_MARKER_START="# PVE-Manager-Status start"
NODE_MARKER_END="# PVE-Manager-Status end"
JS_MARKER_START="// PVE-Manager-Status start"
JS_MARKER_END="// PVE-Manager-Status end"

echo -e "\n⚙️ 当前 Proxmox VE 版本: $pvever"



####################   备份步骤   ####################

echo -e "\n💾 修改开始前备份原文件:"

delete_old_backups() {
    local pattern="$1"
    local description="$2"

    shopt -s nullglob
    local files=($pattern)
    shopt -u nullglob

    if [ ${#files[@]} -gt 0 ]; then
        for file in "${files[@]}"; do
            echo "旧备份清理: $file ♻️"
        done
        rm -f "${files[@]}"
    else
        echo "没有发现任何旧备份文件! ♻️"
    fi
}
echo -e "清理旧的备份文件..."
delete_old_backups "${nodes}.*.bak" "nodes"
delete_old_backups "${pvemanagerlib}.*.bak" "pvemanagerlib"

echo -e "备份当前将要被修改的文件..."
cp "$nodes" "${nodes}.${pvever}.bak"
echo "新备份生成: ${nodes}.${pvever}.bak ✅"
cp "$pvemanagerlib" "${pvemanagerlib}.${pvever}.bak"
echo "新备份生成: ${pvemanagerlib}.${pvever}.bak ✅"



####################   依赖检查 & 环境准备   ####################

# 避免重复修改, 重装 pve-manager
echo -e "\n♻️ 避免重复修改, 重新安装 pve-manager..."
apt-get install --reinstall -y pve-manager

# 软件包依赖
echo -e "\n🗃️ 检查依赖软件包安装情况..."
packages=(sudo sysstat lm-sensors smartmontools linux-cpupower)
missing=()

# 检查依赖状态
installed_list=$(apt list --installed 2>/dev/null)
for pkg in "${packages[@]}"; do
    if echo "$installed_list" | grep -q "^$pkg/"; then
        echo "$pkg: 已安装✅"
    else
        echo "$pkg: 未安装⛔"
        missing+=("$pkg")
    fi
done

# 安装缺失的包
if [ ${#missing[@]} -ne 0 ]; then
    echo -e "\n📦 检查到软件包缺失: ${missing[*]} 开始安装..."
    if ! (apt-get update && apt-get install -y "${missing[@]}"); then
        echo -e "\n⛔ 依赖软件包安装失败! 请检查你的 apt 源配置或网络连接"
        echo && exit 1
    fi
    echo -e "✅ 依赖软件包已成功安装!"
else
    echo -e "所有依赖软件包均已安装!"
fi

# 配置传感器模块
echo -e "\n🧰 开始配置传感器模块..."
sensors-detect --auto > /tmp/sensors

drivers=$(sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors | sed '/Chip /d;/cut/d')

if [ -n "$drivers" ]; then
    echo "发现传感器模块, 正在配置以便开机自动加载"
    for drv in $drivers; do
        modprobe "$drv"
        if grep -qx "$drv" /etc/modules; then
            echo "模块 $drv 已存在于 /etc/modules ➡️"
        else
            echo "$drv" >> /etc/modules
            echo "模块 $drv 已添加至 /etc/modules ✅"
        fi
    done
    if [[ -e /etc/init.d/kmod ]]; then
        echo "正在应用模块配置使其立即生效..."
        /etc/init.d/kmod start &>/dev/null
        echo "模块配置已生效 ✅"
    else
        echo "未找到 /etc/init.d/kmod 跳过此步骤 ➡️"
    fi
    echo "传感器模块已配置完成!"
elif grep -q "No modules to load, skipping modules configuration" /tmp/sensors; then
    echo "未找到需要手动加载的模块, 跳过配置步骤 (可能已由内核自动加载) ➡️"
elif grep -q "Sorry, no sensors were detected" /tmp/sensors; then
    echo "未检测到任何传感器, 跳过配置步骤 (当前环境可能为虚拟机) ⚠️"
else
    echo "发生预期外的错误, 跳过配置步骤! 你的设备可能不支持或内核未包含相关模块 ⛔"
fi

rm -f /tmp/sensors

# 配置必要的执行权限 (替代危险的 chmod +s)
echo -e "\n🔩 配置必要的执行权限..."
echo -e "允许 www-data 用户以 sudo 权限执行特定监控命令"
SUDOERS_FILE="/etc/sudoers.d/pve-manager-status"
# 首先移除可能被添加的 SUID 权限设置, 以防曾经被其它监控脚本添加
binaries=(/usr/sbin/nvme /usr/bin/iostat /usr/bin/sensors /usr/bin/cpupower /usr/sbin/smartctl /usr/sbin/turbostat)
for bin in "${binaries[@]}"; do
    if [[ -e $bin && -u $bin ]]; then
        chmod -s "$bin" && echo "检测到不安全的 SUID 权限已移除: $bin ⚠️"
    fi
done

# 定义需要 sudo 权限执行命令的绝对路径
IOSTAT_PATH=$(command -v iostat)
SENSORS_PATH=$(command -v sensors)
SMARTCTL_PATH=$(command -v smartctl)
TURBOSTAT_PATH=$(command -v turbostat)

# 配置 sudoers 规则内容
echo -e "正在配置 sudoers 规则内容并进行语法检查..."
read -r -d '' SUDOERS_CONTENT << EOM
# Allow www-data user (PVE Web GUI) to run specific hardware monitoring commands
# This file is managed by pve-manager-status.sh (https://github.com/Sagittarius/PVE-Manager-Status)

www-data ALL=(root) NOPASSWD: ${SENSORS_PATH}
www-data ALL=(root) NOPASSWD: ${SMARTCTL_PATH} -a /dev/*
www-data ALL=(root) NOPASSWD: ${SMARTCTL_PATH} -a -j /dev/*
www-data ALL=(root) NOPASSWD: ${IOSTAT_PATH} -d -x -k 1 1
www-data ALL=(root) NOPASSWD: ${TURBOSTAT_PATH} -S -q -s PkgWatt -i 0.1 -n 1 -c package
EOM

# 使用 visudo 在最终添加前对 sudoers 规则执行语法检查
TMP_SUDOERS=$(mktemp)
echo "${SUDOERS_CONTENT}" > "${TMP_SUDOERS}"

if visudo -c -f "${TMP_SUDOERS}" &> /dev/null; then
    echo "sudoers 规则语法检查通过 ✅"
    mv "${TMP_SUDOERS}" "${SUDOERS_FILE}"
    chown root:root "${SUDOERS_FILE}"
    chmod 0440 "${SUDOERS_FILE}"
    echo "已成功配置 sudo 规则于: ${SUDOERS_FILE} 🔐"
else
    echo "⛔ sudoers 规则语法错误, 操作终止!"
    echo -e "\n--- DEBUG INFO START ---"
    echo "生成的 sudoers 规则内容如下:"
    echo "--------------------------------------------------"
    cat "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo
    echo "visudo 语法检查的详细错误信息:"
    echo "--------------------------------------------------"
    visudo -c -f "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo -e "\n--- DEBUG INFO END ---"
    rm -f "${TMP_SUDOERS}"
    echo && exit 1
fi

# 确保 msr 模块被加载并设为开机自启, 为 turbostat 提供支持
modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf



####################   概要页面监控功能实现   ####################

echo -e "\n📋 添加概要页面硬件监控信息..."

# 修改 node.pm 文件前置步骤
tmpf1=$(mktemp /tmp/pve-manager-status.XXXXXX) || exit 1
cat > "$tmpf1" << 'EOF'

        # PVE-Manager-Status start

        my $cpumodes = `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`;
        chomp($cpumodes);
        my $zenpower_core = `sudo sensors | awk '/^zenpower-pci-/{in_zenpower=1; next} in_zenpower && /^SVI2_P_Core:/ {print \$(NF-1); exit}'`;
        my $zenpower_soc = `sudo sensors | awk '/^zenpower-pci-/{in_zenpower=1; next} in_zenpower && /^SVI2_P_SoC:/ {print \$(NF-1); exit}'`;
        chomp($zenpower_core);
        chomp($zenpower_soc);
        my $cpupowers = '';
        if ($zenpower_core ne '' || $zenpower_soc ne '') {
            my $core_power = ($zenpower_core ne '') ? $zenpower_core : 0;
            my $soc_power = ($zenpower_soc ne '') ? $zenpower_soc : 0;
            my $total_power = sprintf("%.2f", $core_power + $soc_power);
            $cpupowers = "source=zenpower\ncore=$core_power\nsoc=$soc_power\ntotal=$total_power";
        } else {
            my $pkg_power = `sudo turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package | awk 'NF { value = \$NF } END { print value }'`;
            chomp($pkg_power);
            $cpupowers = ($pkg_power ne '') ? "source=turbostat\npackage=$pkg_power" : "source=unavailable";
        }
        $res->{cpupower} = $cpumodes . "\n" . $cpupowers;

        my $cpufreqs = `lscpu | grep MHz`;
        my $threadfreqs = `cat /proc/cpuinfo | grep -i "cpu MHz"`;
        $res->{cpufreq} = $cpufreqs . $threadfreqs;

        $res->{sensors} = `sudo sensors`;
EOF

for x in {0..9}; do
    for dev in "/dev/nvme${x}" "/dev/nvme${x}n1"; do
        if [ -b "$dev" ]; then
            cat >> "$tmpf1" << EOF

        my \$nvme${x}_info = \`sudo smartctl -a $dev | grep -E "Model Number|(?=Total|Namespace)[^:]+Capacity|Temperature:|Available Spare:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors"\`;
        my \$nvme${x}_io = \`sudo iostat -d -x -k 1 1 | grep -E "^${dev##*/}"\`;
        \$res->{nvme${x}_status} = \$nvme${x}_info . \$nvme${x}_io;
EOF
            break
        fi
    done
done

cat >> "$tmpf1" << 'EOF'

        my @sata_status = ();
        foreach my $dev (glob('/dev/sd?')) {
            next if !-b $dev;
            my $sata_json = `sudo smartctl -a -j $dev | tr -d '\n'`;
            push @sata_status, $sata_json if $sata_json;
        }
        $res->{sata_status} = join("\n", @sata_status);

        # PVE-Manager-Status end
EOF

# 在实际修改前检查锚点文本是否存在, 若不存在则报错退出停止修改
if ! grep -q 'PVE::pvecfg::version_text' "$nodes"; then
    echo "⛔ 在 $nodes 中未找到锚点, 操作终止!"
    rm -f "$tmpf1"
    echo -e "⚠️ 锚点'PVE::pvecfg::version_text', 文件可能已更新或与当前版本不兼容\n" && exit 1
fi

# 应用更改
sed -i "/$NODE_MARKER_START/,/$NODE_MARKER_END/d" "$nodes"
sed -i '/PVE::pvecfg::version_text/ r '"$tmpf1"'' "$nodes"

# 验证修改是否成功
if grep -q 'cpupower' "$nodes"; then
    echo "已完成修改: $nodes ✅"
else
    echo "⛔ 检查对 $nodes 添加的内容未生效!"
    rm -f "$tmpf1"
    echo -e "⚠️ 请检查文件权限或手动检查文件内容\n" && exit 1
fi

rm -f "$tmpf1"



# 修改 pvemanagerlib.js 文件前置步骤
tmpf2=$(mktemp /tmp/pve-manager-status.XXXXXX) || exit 1
cat > "$tmpf2" << 'EOF'
        // PVE-Manager-Status start
        {
            itemId: 'cpupower',
            colspan: 2,
            printBar: false,
            title: gettext('CPU能耗'),
            textField: 'cpupower',
            renderer:function(value){
                const palette = {
                    low: '#3A7D6A',
                    mid: '#C28B2C',
                    high: '#C45B5B',
                    text: '#4B5563',
                    muted: '#6B7280'
                };
                function iconBolt(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.6;margin-right:4px"><path d="M9 1L3 9h4l-1 6 6-8H8l1-6z"/></svg>`;
                }
                function label(text) {
                    return `<span style="color:${palette.text}; font-weight:600;">${text}</span>`;
                }
                function wrap(icon, labelText, valueHtml) {
                    return `<span style="display:inline-flex;align-items:baseline;gap:4px;">${icon}${label(labelText)}<span style="color:${palette.muted};">:</span>${valueHtml}</span>`;
                }
                function colorizeCpuMode(mode) {
                    if (mode === 'powersave') return `<span style="color:${palette.low}; font-weight:600;">${mode}</span>`;
                    if (mode === 'performance') return `<span style="color:${palette.high}; font-weight:600;">${mode}</span>`;
                    return `<span style="color:${palette.mid}; font-weight:600;">${mode}</span>`;
                }
                function colorizeCpuPower(power) {
                    const powerNum = parseFloat(power);
                    const formattedPower = powerNum.toFixed(2).padStart(5, '0');
                    const valueStyle = 'display:inline-block;min-width:5ch;text-align:right;font-variant-numeric:tabular-nums;';
                    if (powerNum < 20) return `<span style="color:${palette.low}; font-weight:600;${valueStyle}">${formattedPower} W</span>`;
                    if (powerNum < 50) return `<span style="color:${palette.mid}; font-weight:600;${valueStyle}">${formattedPower} W</span>`;
                    return `<span style="color:${palette.high}; font-weight:600;${valueStyle}">${formattedPower} W</span>`;
                }
                function muted(text) {
                    return `<span style="color:${palette.muted}; font-weight:600;">${text}</span>`;
                }
                function fixedWidthMuted(text) {
                    return `<span style="color:${palette.muted}; font-weight:600;display:inline-block;min-width:7ch;text-align:right;font-variant-numeric:tabular-nums;">${text}</span>`;
                }
                const lines = value.split('\n').map(line => line.trim()).filter(Boolean);
                const w0 = lines[0] || 'unknown';
                const metrics = {};
                for (const line of lines.slice(1)) {
                    const [key, rawValue] = line.split('=');
                    if (key && rawValue !== undefined) {
                        metrics[key] = rawValue;
                    }
                }
                const powerValue = metrics.total || metrics.package || '';
                const powerHtml = powerValue ? colorizeCpuPower(powerValue) : fixedWidthMuted('不可用');
                return `${wrap(iconBolt(palette.text), 'CPU功耗', powerHtml)}`
            }
        },
        {
            itemId: 'cpufreq',
            colspan: 2,
            printBar: false,
            title: gettext('CPU频率'),
            textField: 'cpufreq',
            renderer:function(value){
                const palette = {
                    low: '#3A7D6A',
                    mid: '#C28B2C',
                    high: '#C45B5B',
                    text: '#4B5563',
                    muted: '#6B7280'
                };
                const sep = '<span style="color:#9CA3AF;"> | </span>';
                function iconActivity(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.8;vertical-align:-2px;margin-right:4px"><polyline points="1 8 4 8 6 4 9 12 11 8 15 8"/></svg>`;
                }
                function label(text) {
                    return `<span style="color:${palette.text}; font-weight:600;">${text}</span>`;
                }
                function colorizeCpuFreq(freq) {
                    const freqNum = parseFloat(freq);
                    if (freqNum < 1500) return `<span style="color:${palette.low}; font-weight:600;">${freq} MHz</span>`;
                    if (freqNum < 3000) return `<span style="color:${palette.mid}; font-weight:600;">${freq} MHz</span>`;
                    return `<span style="color:${palette.high}; font-weight:600;">${freq} MHz</span>`;
                }
                const f0 = value.match(/cpu MHz.*?([\d]+)/)[1];
                const f1 = value.match(/CPU min MHz.*?([\d]+)/)[1];
                const f2 = value.match(/CPU max MHz.*?([\d]+)/)[1];
                const muted = `<span style="color:${palette.muted}; font-weight:600;">`;
                return `${iconActivity(palette.text)}${label('CPU实时')} ${colorizeCpuFreq(f0)}${sep}${label('最小')} ${muted}${f1} MHz</span>${sep}${label('最大')} ${muted}${f2} MHz</span>`
            }
        },
        {
            itemId: 'sensors',
            colspan: 2,
            printBar: false,
            title: gettext('传感器'),
            textField: 'sensors',
            renderer: function(value) {
                const palette = {
                    low: '#3A7D6A',
                    mid: '#C28B2C',
                    high: '#C45B5B',
                    text: '#4B5563',
                    muted: '#6B7280'
                };
                function iconChip(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><rect x="4" y="4" width="8" height="8" rx="1"/><path d="M2 6h2M2 10h2M12 6h2M12 10h2M6 2v2M10 2v2M6 12v2M10 12v2"/></svg>`;
                }
                function iconGpu(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><rect x="2" y="3" width="12" height="8" rx="1"/><path d="M6 13h4"/></svg>`;
                }
                function iconBoard(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><rect x="3" y="3" width="10" height="10" rx="1"/><circle cx="6" cy="6" r="1"/><circle cx="10" cy="10" r="1"/><path d="M8 3v3M3 8h3"/></svg>`;
                }
                function iconFan(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><circle cx="8" cy="8" r="1"/><path d="M8 3c2 0 3 2 1 3M13 8c0 2-2 3-3 1M8 13c-2 0-3-2-1-3M3 8c0-2 2-3 3-1"/></svg>`;
                }
                const icons = {
                    cpu: iconChip(palette.text),
                    gpu: iconGpu(palette.text),
                    board: iconBoard(palette.text),
                    fan: iconFan(palette.text)
                };
                function label(text) {
                    return `<span style="color:${palette.text}; font-weight:600;">${text}</span>`;
                }
                function colorizeCpuTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:${palette.low}; font-weight:600;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:${palette.mid}; font-weight:600;">${temp}°C</span>`;
                    return `<span style="color:${palette.high}; font-weight:600;">${temp}°C</span>`;
                }
                function colorizeGpuTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:${palette.low}; font-weight:600;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:${palette.mid}; font-weight:600;">${temp}°C</span>`;
                    return `<span style="color:${palette.high}; font-weight:600;">${temp}°C</span>`;
                }
                function colorizeAcpiTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:${palette.low}; font-weight:600;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:${palette.mid}; font-weight:600;">${temp}°C</span>`;
                    return `<span style="color:${palette.high}; font-weight:600;">${temp}°C</span>`;
                }
                function colorizeFanRpm(rpm) {
                    const rpmNum = parseFloat(rpm);
                    if (rpmNum < 1500) return `<span style="color:${palette.low}; font-weight:600;">${rpm}转/分钟</span>`;
                    if (rpmNum < 3000) return `<span style="color:${palette.mid}; font-weight:600;">${rpm}转/分钟</span>`;
                    return `<span style="color:${palette.high}; font-weight:600;">${rpm}转/分钟</span>`;
                }
                value = value.replace(/Â/g, '');
                const cpuData = [];
                const gpuTemps = [];
                const acpiTemps = [];
                const fanGroups = [];
                let cpus = value.matchAll(/^(?:coretemp-isa|k10temp-pci|zenpower-pci)-(\w{4})$\n(?:.*\n)*?((?:(?:Package id \d+|Core \d+|Tctl|Tdie):.*\n)+)/gm);
                for (const cpu of cpus) {
                    let cpuNumber = parseInt(cpu[1], 10);
                    cpuData[cpuNumber] = {
                        packages: [],
                        cores: []
                    };

                    let packages = cpu[2].matchAll(/^(?:Package id \d+|Tctl):\s*\+([^°C ]+).*$/gm);
                    for (const package of packages) {
                        cpuData[cpuNumber].packages.push(package[1]);
                    }
                    let cores = cpu[2].matchAll(/^Core (\d+):\s*\+([^°C ]+).*$/gm);
                    for (const core of cores) {
                        var corecombi = `${label('核心 ' + core[1])}: ${colorizeCpuTemp(core[2])}`
                        cpuData[cpuNumber].cores.push(corecombi);
                    }
                }

                let output = '';
                for (const [i, cpu] of cpuData.entries()) {
                    if (!cpu) {
                        continue;
                    }
                    if (cpu.packages.length > 0) {
                        for (const packageTemp of cpu.packages) {
                            output += `${icons.cpu}${label('CPU ' + i)}: ${colorizeCpuTemp(packageTemp)} | `;
                        }
                    }
                }

                let gpus = value.matchAll(/^amdgpu-pci-(\w*)$\n((?!edge:)[ \S]*?\n)*((?:edge)[\s\S]*?^\n)+/gm);
                for (const gpu of gpus) {
                    let edges = gpu[3].matchAll(/^edge:\s*\+([^°C ]+).*$/gm);
                    for (const edge of edges) {
                        gpuTemps.push(edge[1]);
                    }
                }
                if (gpuTemps.length > 0) {
                    output += `${icons.gpu}${label('核显')}: `;
                    for (const edgeTemp of gpuTemps) {
                        output += `${colorizeGpuTemp(edgeTemp)}, `;
                    }
                    output = output.slice(0, -2);
                    output += ' | ';
                }

                let acpitzs = value.matchAll(/^acpitz-acpi-(\d*)$\n.*?\n((?:temp)[\s\S]*?^\n)+/gm);
                for (const acpitz of acpitzs) {
                    let acpisensors = acpitz[2].matchAll(/^temp\d+:\s*\+([^°C ]+).*$/gm);
                    for (const acpisensor of acpisensors) {
                        acpiTemps.push(acpisensor[1]);
                    }
                }
                if (acpiTemps.length > 0) {
                    output += `${icons.board}${label('主板')}: `;
                    for (const acpiTemp of acpiTemps) {
                        output += `${colorizeAcpiTemp(acpiTemp)}, `;
                    }
                    output = output.slice(0, -2);
                    output += ' | ';
                }

                let FunStates = value.matchAll(/^(?:[a-zA-z]{2,3}\d{4}|dell_smm)-isa-(\w{4})$\n((?![ \S]+: *\d+ +RPM)[ \S]*?\n)*((?:[ \S]+: *\d+ RPM)[\s\S]*?^\n)+/gm);
                for (const FunState of FunStates) {
                    const fanGroup = {
                        cpufans: [],
                        motherboardfans: [],
                        pumpfans: [],
                        systemfans: []
                    };

                    let rotationals = FunState[3].match(/^([ \S]+: *[0-9]\d* +RPM)[ \S]*?$/gm);
                    for (const rotational of rotationals) {
                        if (rotational.toLowerCase().indexOf("pump") !== -1 || rotational.toLowerCase().indexOf("opt") !== -1){
                            let pumpfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                            for (const pumpfan of pumpfans) {
                                fanGroup.pumpfans.push(pumpfan[1]);
                            }
                        } else if (rotational.toLowerCase().indexOf("cpu") !== -1 || rotational.toLowerCase().indexOf("processor") !== -1){
                            let cpufans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                            for (const cpufan of cpufans) {
                                fanGroup.cpufans.push(cpufan[1]);
                            }
                        } else if (rotational.toLowerCase().indexOf("motherboard") !== -1){
                            let motherboardfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                            for (const motherboardfan of motherboardfans) {
                                fanGroup.motherboardfans.push(motherboardfan[1]);
                            }
                        } else {
                            let systemfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                            for (const systemfan of systemfans) {
                                fanGroup.systemfans.push(systemfan[1]);
                            }
                        }
                    }
                    fanGroups.push(fanGroup);
                }

                for (const fanGroup of fanGroups) {
                    if (fanGroup.cpufans.length > 0 || fanGroup.motherboardfans.length > 0 || fanGroup.pumpfans.length > 0 || fanGroup.systemfans.length > 0) {
                        output += `${icons.fan}${label('风扇')}: `;
                        if (fanGroup.cpufans.length > 0) {
                            output += 'CPU-';
                            for (const cpufanValue of fanGroup.cpufans) {
                                output += `${colorizeFanRpm(cpufanValue)}, `;
                            }
                        }

                        if (fanGroup.motherboardfans.length > 0) {
                            output += '主板-';
                            for (const motherboardfanValue of fanGroup.motherboardfans) {
                                output += `${colorizeFanRpm(motherboardfanValue)}, `;
                            }
                        }

                        if (fanGroup.pumpfans.length > 0) {
                            output += '水冷-';
                            for (const pumpfanValue of fanGroup.pumpfans) {
                                output += `${colorizeFanRpm(pumpfanValue)}, `;
                            }
                        }

                        if (fanGroup.systemfans.length > 0) {
                            if (fanGroup.cpufans.length > 0 || fanGroup.pumpfans.length > 0) {
                                output += '系统-';
                            }
                            for (const systemfanValue of fanGroup.systemfans) {
                                output += `${colorizeFanRpm(systemfanValue)}, `;
                            }
                        }
                        output = output.slice(0, -2);
                        output += ' | ';
                    }
                }

                for (const cpu of cpuData) {
                    if (!cpu) {
                        continue;
                    }
                    if (cpu.cores.length > 1) {
                        output += '\n';
                        for (j = 1;j < cpu.cores.length;) {
                            for (const coreTemp of cpu.cores) {
                                output += `${coreTemp} | `;
                                j++;
                                if ((j-1) % 4 == 0){
                                    output = output.slice(0, -2);
                                    output += '\n';
                                }
                            }
                        }
                        output = output.slice(0, -2);
                    }
                    output += '\n';
                }

                output = output.slice(0, -2);
                return output.replace(/\n/g, '<br>');
            }
        },
EOF

for x in {0..9}; do
    for dev in "/dev/nvme${x}" "/dev/nvme${x}n1"; do
        if [ -b "$dev" ]; then
            cat >> "$tmpf2" << EOF
        {
            itemId: 'nvme${x}-status',
            colspan: 2,
            printBar: false,
            title: gettext('NVMe${x}硬盘'),
            textField: 'nvme${x}_status',
            renderer:function(value){
                const palette = {
                    low: '#3A7D6A',
                    mid: '#C28B2C',
                    high: '#C45B5B',
                    text: '#4B5563',
                    muted: '#6B7280'
                };
                const sep = '<span style="color:#9CA3AF;"> | </span>';
                function iconDisk(color) {
                    return '<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:' + color + ';fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><rect x="2" y="3" width="12" height="10" rx="2"/><circle cx="11" cy="8" r="1"/></svg>';
                }
                function iconGauge(color) {
                    return '<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:' + color + ';fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><path d="M3 12a5 5 0 0 1 10 0"/><path d="M8 8l3-2"/><circle cx="8" cy="8" r="1"/></svg>';
                }
                function iconThermo(color) {
                    return '<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:' + color + ';fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><path d="M9 3a2 2 0 0 0-4 0v6a3 3 0 1 0 4 0V3z"/><path d="M7 6v4"/></svg>';
                }
                function iconActivity(color) {
                    return '<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:' + color + ';fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><polyline points="1 8 4 8 6 4 9 12 11 8 15 8"/></svg>';
                }
                function iconClock(color) {
                    return '<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:' + color + ';fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><circle cx="8" cy="8" r="6"/><path d="M8 4v4l3 2"/></svg>';
                }
                function label(text) {
                    return '<span style="color:' + palette.text + '; font-weight:600;">' + text + '</span>';
                }
                function muted(text) {
                    return '<span style="color:' + palette.muted + '; font-weight:600;">' + text + '</span>';
                }
                function getSsdLifeColor(life) {
                    const lifeNum = parseFloat(life);
                    if (lifeNum < 50) return palette.high;
                    if (lifeNum < 80) return palette.mid;
                    return palette.low;
                }
                function colorizeSsdModel(model, life) {
                    const color = getSsdLifeColor(life);
                    return \`<span style="color:\${color}; font-weight:600;">\${model}</span>\`;
                }
                function colorizeSsdLife(life) {
                    const color = getSsdLifeColor(life);
                    return \`<span style="color:\${color}; font-weight:600;">\${life}%</span>\`;
                }
                function colorizeSsdTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 50) return \`<span style="color:\${palette.low}; font-weight:600;">\${temp}°C</span>\`;
                    if (tempNum < 70) return \`<span style="color:\${palette.mid}; font-weight:600;">\${temp}°C</span>\`;
                    return \`<span style="color:\${palette.high}; font-weight:600;">\${temp}°C</span>\`;
                }
                function colorizeSsdLoad(load) {
                    const loadNum = parseFloat(load);
                    if (loadNum < 50) return \`<span style="color:\${palette.low}; font-weight:600;">\${load}%</span>\`;
                    if (loadNum < 80) return \`<span style="color:\${palette.mid}; font-weight:600;">\${load}%</span>\`;
                    return \`<span style="color:\${palette.high}; font-weight:600;">\${load}%</span>\`;
                }
                function colorizeIoSpeed(speed) {
                    const speedNum = parseFloat(speed);
                    if (speedNum > 1000) return \`<span style="color:\${palette.high}; font-weight:600;">\${speed}MB/s</span>\`;
                    if (speedNum < 100) return \`<span style="color:\${palette.low}; font-weight:600;">\${speed}MB/s</span>\`;
                    return \`<span style="color:\${palette.mid}; font-weight:600;">\${speed}MB/s</span>\`;
                }
                function colorizeIoLatency(latency) {
                    const latencyNum = parseFloat(latency);
                    if (latencyNum > 10) return \`<span style="color:\${palette.high}; font-weight:600;">\${latency}ms</span>\`;
                    if (latencyNum < 1) return \`<span style="color:\${palette.low}; font-weight:600;">\${latency}ms</span>\`;
                    return \`<span style="color:\${palette.mid}; font-weight:600;">\${latency}ms</span>\`;
                }
                if (value.length > 0) {
                    value = value.replace(/Â/g, '');
                    let data = [];
                    let nvmeNumber = -1;

                    let nvmes = value.matchAll(/(^(?:Model|Total|Temperature:|Available Spare:|Percentage|Data|Power|Unsafe|Integrity Errors|nvme)[\s\S]*)+/gm);
                    
                    for (const nvme of nvmes) {
                        if (/Model Number:/.test(nvme[1])) {
                            nvmeNumber++; 
                            data[nvmeNumber] = {
                                Models: [],
                                Integrity_Errors: [],
                                Capacitys: [],
                                Temperatures: [],
                                Available_Spares: [],
                                Useds: [],
                                Reads: [],
                                Writtens: [],
                                Cycles: [],
                                Hours: [],
                                Shutdowns: [],
                                States: [],
                                r_kBs: [],
                                r_awaits: [],
                                w_kBs: [],
                                w_awaits: [],
                                utils: []
                            };
                        }

                        if (nvmeNumber === -1) continue;

                        let Models = nvme[1].matchAll(/^Model Number: *([ \S]*)$/gm);
                        for (const Model of Models) {
                            data[nvmeNumber]['Models'].push(Model[1]);
                        }

                        let Integrity_Errors = nvme[1].matchAll(/^Media and Data Integrity Errors: *([ \S]*)$/gm);
                        for (const Integrity_Error of Integrity_Errors) {
                            data[nvmeNumber]['Integrity_Errors'].push(Integrity_Error[1]);
                        }

                        let Capacitys = nvme[1].matchAll(/^(?=Total|Namespace)[^:]+Capacity:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Capacity of Capacitys) {
                            data[nvmeNumber]['Capacitys'].push(Capacity[1]);
                        }

                        let Temperatures = nvme[1].matchAll(/^Temperature: *([\d]*)[ \S]*$/gm);
                        for (const Temperature of Temperatures) {
                            data[nvmeNumber]['Temperatures'].push(Temperature[1]);
                        }

                        let Available_Spares = nvme[1].matchAll(/^Available Spare: *([\d]*%)[ \S]*$/gm);
                        for (const Available_Spare of Available_Spares) {
                            data[nvmeNumber]['Available_Spares'].push(Available_Spare[1]);
                        }

                        let Useds = nvme[1].matchAll(/^Percentage Used: *([ \S]*)%$/gm);
                        for (const Used of Useds) {
                            data[nvmeNumber]['Useds'].push(Used[1]);
                        }

                        let Reads = nvme[1].matchAll(/^Data Units Read:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Read of Reads) {
                            data[nvmeNumber]['Reads'].push(Read[1]);
                        }

                        let Writtens = nvme[1].matchAll(/^Data Units Written:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Written of Writtens) {
                            data[nvmeNumber]['Writtens'].push(Written[1]);
                        }

                        let Cycles = nvme[1].matchAll(/^Power Cycles: *([ \S]*)$/gm);
                        for (const Cycle of Cycles) {
                            data[nvmeNumber]['Cycles'].push(Cycle[1]);
                        }

                        let Hours = nvme[1].matchAll(/^Power On Hours: *([ \S]*)$/gm);
                        for (const Hour of Hours) {
                            data[nvmeNumber]['Hours'].push(Hour[1]);
                        }

                        let Shutdowns = nvme[1].matchAll(/^Unsafe Shutdowns: *([ \S]*)$/gm);
                        for (const Shutdown of Shutdowns) {
                            data[nvmeNumber]['Shutdowns'].push(Shutdown[1]);
                        }

                        let States = nvme[1].matchAll(/^nvme\S+(( *\d+\.\d{2}){22})/gm);
                        for (const State of States) {
                            data[nvmeNumber]['States'].push(State[1]);
                            const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
                            if (IO_array.length > 0) {
                                data[nvmeNumber]['r_kBs'].push(IO_array[1]);
                                data[nvmeNumber]['r_awaits'].push(IO_array[4]);
                                data[nvmeNumber]['w_kBs'].push(IO_array[7]);
                                data[nvmeNumber]['w_awaits'].push(IO_array[10]);
                                data[nvmeNumber]['utils'].push(IO_array[21]);
                            }
                        }
                    }

                    let output = '';
                    for (const [i, nvme] of data.entries()) {
                        if (i > 0) output += '<br><br>';

                        if (nvme.Models.length > 0) {
                            output += iconDisk(palette.text) + colorizeSsdModel(nvme.Models[0], 100 - Number(nvme.Useds[0]));

                            if (nvme.Integrity_Errors.length > 0) {
                                for (const nvmeIntegrity_Error of nvme.Integrity_Errors) {
                                    if (nvmeIntegrity_Error != 0) {
                                        output += ' (';
                                        output += \`0E: \${nvmeIntegrity_Error}-故障！\`;
                                        if (nvme.Available_Spares.length > 0) {
                                            output += ', ';
                                            for (const Available_Spare of nvme.Available_Spares) {
                                                output += \`备用空间: \${Available_Spare}\`;
                                            }
                                        }
                                        output += ')';
                                    }
                                }
                            }
                        }

                        if (nvme.Capacitys.length > 0) {
                            output += sep;
                            for (const nvmeCapacity of nvme.Capacitys) {
                                output += label('容量') + ': ' + muted(nvmeCapacity.replace(/ |,/gm, ''));
                            }
                        }
                        output += '<br>';

                        if (nvme.Useds.length > 0) {
                            for (const nvmeUsed of nvme.Useds) {
                                output += iconGauge(palette.text) + label('寿命') + ': ' + colorizeSsdLife(100-Number(nvmeUsed)) + ' ';
                                if (nvme.Reads.length > 0) {
                                    output += '(';
                                    for (const nvmeRead of nvme.Reads) {
                                        output += \`已读 \${nvmeRead.replace(/ |,/gm, '')}\`;
                                        output += ')';
                                    }
                                }

                                if (nvme.Writtens.length > 0) {
                                    output = output.slice(0, -1);
                                    output += ', ';
                                    for (const nvmeWritten of nvme.Writtens) {
                                        output += \`已写 \${nvmeWritten.replace(/ |,/gm, '')}\`;
                                    }
                                    output += ')';
                                }
                            }
                        }

                        if (nvme.Temperatures.length > 0) {
                            output += sep;
                            for (const nvmeTemperature of nvme.Temperatures) {
                                output += iconThermo(palette.text) + label('温度') + ': ' + colorizeSsdTemp(nvmeTemperature);
                            }
                        }

                        if (nvme.utils.length > 0) {
                            output += sep;
                            for (const nvme_util of nvme.utils) {
                                output += iconActivity(palette.text) + label('负载') + ': ' + colorizeSsdLoad(nvme_util);
                            }
                        }
                        output += '<br>';

                        if (nvme.States.length > 0) {
                            output += iconActivity(palette.text) + label('I/O') + ': ';
                            if (nvme.r_kBs.length > 0 || nvme.r_awaits.length > 0) {
                                output += '读-';
                                if (nvme.r_kBs.length > 0) {
                                    for (const nvme_r_kB of nvme.r_kBs) {
                                        var nvme_r_mB = \`\${nvme_r_kB}\` / 1024;
                                        nvme_r_mB = nvme_r_mB.toFixed(2);
                                        output += \`速度 \${colorizeIoSpeed(nvme_r_mB)}\`;
                                    }
                                }
                                if (nvme.r_awaits.length > 0) {
                                    output += ', ';
                                    for (const nvme_r_await of nvme.r_awaits) {
                                        output += \`延迟 \${colorizeIoLatency(nvme_r_await)}\`;
                                    }
                                }
                            }

                            if (nvme.w_kBs.length > 0 || nvme.w_awaits.length > 0) {
                                if (nvme.r_kBs.length > 0 || nvme.r_awaits.length > 0) {
                                    output += ' / ';
                                }
                                output += '写-';
                                if (nvme.w_kBs.length > 0) {
                                    for (const nvme_w_kB of nvme.w_kBs) {
                                        var nvme_w_mB = \`\${nvme_w_kB}\` / 1024;
                                        nvme_w_mB = nvme_w_mB.toFixed(2);
                                        output += \`速度 \${colorizeIoSpeed(nvme_w_mB)}\`;
                                    }
                                }
                                if (nvme.w_awaits.length > 0) {
                                    output += ', ';
                                    for (const nvme_w_await of nvme.w_awaits) {
                                        output += \`延迟 \${colorizeIoLatency(nvme_w_await)}\`;
                                    }
                                }
                            }
                        }

                        if (nvme.Cycles.length > 0) {
                            output += '<br>';
                            output += iconClock(palette.text) + label('通电') + ': ';
                            for (const nvmeCycle of nvme.Cycles) {
                                output += muted(nvmeCycle.replace(/ |,/gm, '')) + '次';
                            }

                            if (nvme.Shutdowns.length > 0) {
                                output += ', ';
                                for (const nvmeShutdown of nvme.Shutdowns) {
                                    output += label('不安全断电') + ' ' + muted(nvmeShutdown.replace(/ |,/gm, '')) + '次';
                                    break
                                }
                            }

                            if (nvme.Hours.length > 0) {
                                output += ', ';
                                for (const nvmeHour of nvme.Hours) {
                                    output += label('累计') + ' ' + muted(nvmeHour.replace(/ |,/gm, '')) + '小时';
                                }
                            }
                        }
                    }
                    return output;

                } else {
                    return '提示: 未安装 NVMe硬盘 或已直通 NVMe 控制器!';
                }
            },
        },
EOF
            break
        fi
    done
done

cat >> "$tmpf2" << 'EOF'
        {
            itemId: 'sata_status',
            colspan: 2,
            printBar: false,
            title: gettext('SATA硬盘'),
            textField: 'sata_status',
            renderer: function(value) {
                const palette = {
                    low: '#3A7D6A',
                    mid: '#C28B2C',
                    high: '#C45B5B',
                    text: '#4B5563',
                    muted: '#6B7280'
                };
                const sep = '<span style="color:#9CA3AF;"> | </span>';
                function iconDisk(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><rect x="2" y="3" width="12" height="10" rx="2"/><circle cx="11" cy="8" r="1"/></svg>`;
                }
                function iconThermo(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><path d="M9 3a2 2 0 0 0-4 0v6a3 3 0 1 0 4 0V3z"/><path d="M7 6v4"/></svg>`;
                }
                function iconClock(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><circle cx="8" cy="8" r="6"/><path d="M8 4v4l3 2"/></svg>`;
                }
                function iconShield(color) {
                    return `<svg viewBox="0 0 16 16" style="width:14px;height:14px;stroke:${color};fill:none;stroke-width:1.6;vertical-align:-2px;margin-right:4px"><path d="M8 2l5 2v4c0 3-2.2 4.8-5 6-2.8-1.2-5-3-5-6V4l5-2z"/></svg>`;
                }
                function label(text) {
                    return `<span style="color:${palette.text}; font-weight:600;">${text}</span>`;
                }
                function muted(text) {
                    return `<span style="color:${palette.muted}; font-weight:600;">${text}</span>`;
                }
                function colorizeHddTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 40) return `<span style="color:${palette.low}; font-weight:600;">${temp}°C</span>`;
                    if (tempNum < 50) return `<span style="color:${palette.mid}; font-weight:600;">${temp}°C</span>`;
                    return `<span style="color:${palette.high}; font-weight:600;">${temp}°C</span>`;
                }
                function colorizeSmart(passed) {
                    if (passed) return `<span style="color:${palette.low}; font-weight:600;">正常</span>`;
                    return `<span style="color:${palette.high}; font-weight:600;">警告!</span>`;
                }
                function renderJsonDevice(jsonData) {
                    if (!jsonData || !jsonData.model_name) {
                        return '';
                    }
                    let output = `${iconDisk(palette.text)}${label(jsonData.model_name)}<br>`;
                    if (jsonData.temperature?.current !== undefined) {
                        output += `${iconThermo(palette.text)}${label('温度')}: ${colorizeHddTemp(jsonData.temperature.current)}`;
                    }
                    if (jsonData.power_on_time?.hours !== undefined) {
                        if (output.length > 0) output += sep;
                        output += `${iconClock(palette.text)}${label('通电')}: ${muted(jsonData.power_on_time.hours)}小时`;
                        if (jsonData.power_cycle_count !== undefined) {
                            output += `, ${label('次数')}: ${muted(jsonData.power_cycle_count)}`;
                        }
                    }
                    if (jsonData.smart_status?.passed !== undefined) {
                        if (output.length > 0) output += sep;
                        output += `${iconShield(palette.text)}${label('SMART')}: ${colorizeSmart(jsonData.smart_status.passed)}`;
                    }
                    return output;
                }
                if (value.length > 0) {
                    const jsonOutputs = [];
                    for (const line of value.split('\n')) {
                        const trimmed = line.trim();
                        if (!trimmed) {
                            continue;
                        }
                        try {
                            const jsonData = JSON.parse(trimmed);
                            const rendered = renderJsonDevice(jsonData);
                            if (rendered) {
                                jsonOutputs.push(rendered);
                            }
                        } catch (e) {
                        }
                    }
                    if (jsonOutputs.length > 0) {
                        return jsonOutputs.join('<br>');
                    }
                        let outputs = [];
                        let devices = value.matchAll(/(\s*(Model|Device Model|Vendor).*:\s*[\s\S]*?\n){1,2}^User.*\[([\s\S]*?)\]\n^\s*9[\s\S]*?\-\s*([\d]+)[\s\S]*?(\n(^19[0,4][\s\S]*?$){1,2}|\s{0}$)/gm);
                        for (const device of devices) {
                        let devicemodel = '';
                        if (device[1].indexOf("Family") !== -1) {
                        devicemodel = device[1].replace(/.*Model Family:\s*([\s\S]*?)\n^Device Model:\s*([\s\S]*?)\n/m, '$1 - $2');
                        } else if (device[1].match(/Vendor/)) {
                        devicemodel = device[1].replace(/.*Vendor:\s*([\s\S]*?)\n^.*Model:\s*([\s\S]*?)\n/m, '$1 $2');
                        } else {
                        devicemodel = device[1].replace(/.*(Model|Device Model):\s*([\s\S]*?)\n/m, '$2');
                        }
                        let capacity = device[3] ? device[3].replace(/ |,/gm, '') : "未知容量";
                        let powerOnHours = device[4] || "未知";
                        let deviceOutput = '';
                        if (value.indexOf("Min/Max") !== -1) {
                        let devicetemps = device[6]?.matchAll(/19[0,4][\s\S]*?\-\s*(\d+)(\s\(Min\/Max\s(\d+)\/(\d+)\)$|\s{0}$)/gm);
                        for (const devicetemp of devicetemps || []) {
                            deviceOutput = `${iconDisk(palette.text)}${label(devicemodel)}<br>${label('容量')}: ${muted(capacity)}${sep}${label('已通电')}: ${muted(powerOnHours)}小时${sep}${iconThermo(palette.text)}${label('温度')}: ${colorizeHddTemp(devicetemp[1])}`;
                            outputs.push(deviceOutput);
                        }
                        } else if (value.indexOf("Temperature") !== -1 || value.match(/Airflow_Temperature/)) {
                        let devicetemps = device[6]?.matchAll(/19[0,4][\s\S]*?\-\s*(\d+)/gm);
                        for (const devicetemp of devicetemps || []) {
                        deviceOutput = `${iconDisk(palette.text)}${label(devicemodel)}<br>${label('容量')}: ${muted(capacity)}${sep}${label('已通电')}: ${muted(powerOnHours)}小时${sep}${iconThermo(palette.text)}${label('温度')}: ${colorizeHddTemp(devicetemp[1])}`;
                        outputs.push(deviceOutput);
                        }
                        } else {
                        if (value.match(/\/dev\/sd[a-z]/)) {
                            deviceOutput = `${iconDisk(palette.text)}${label(devicemodel)}<br>${label('容量')}: ${muted(capacity)}${sep}${label('已通电')}: ${muted(powerOnHours)}小时${sep}${label('提示')}: 设备存在但未报告温度信息`;
                            outputs.push(deviceOutput);
                        } else {
                            deviceOutput = `${iconDisk(palette.text)}${label(devicemodel)}<br>${label('容量')}: ${muted(capacity)}${sep}${label('已通电')}: ${muted(powerOnHours)}小时${sep}${label('提示')}: 未检测到温度传感器`;
                            outputs.push(deviceOutput);
                        }
                        }
                        }
                        if (!outputs.length && value.length > 0) {
                        let fallbackDevices = value.matchAll(/(\/dev\/sd[a-z]).*?Model:([\s\S]*?)\n/gm);
                        for (const fallbackDevice of fallbackDevices || []) {
                            outputs.push(`${fallbackDevice[2].trim()}<br>提示: 设备存在但无法获取完整信息`);
                        }
                        }
                        return outputs.length ? outputs.join('<br>') : '提示: 检测到硬盘但无法识别详细信息';
                    } else {
                        return '提示: 未安装 SATA硬盘 或已直通 SATA控制器!';
                }
            }
        },
        // PVE-Manager-Status end
EOF

# 计算插入行号
ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' $pvemanagerlib)

# 在实际修改前检查行号是否有效, 若无效则报错退出停止修改
if ! [[ "$ln" =~ ^[0-9]+$ ]]; then
    echo "⛔ 在 $pvemanagerlib 中计算插入位置失败, 操作终止!"
    rm -f "$tmpf2"
    echo -e "⚠️ 锚点'pveversion', 文件可能已更新或与当前版本不兼容\n" && exit 1
fi

# 应用更改
sed -i "/$JS_MARKER_START/,/$JS_MARKER_END/d" "$pvemanagerlib"
sed -i "${ln}r $tmpf2" "$pvemanagerlib"

# 验证修改是否成功
if grep -q "itemId: 'cpupower'" "$pvemanagerlib"; then
    echo "已完成修改: $pvemanagerlib ✅"
else
    echo "⛔ 检查对 $pvemanagerlib 添加的内容未生效!"
    rm -f "$tmpf2"
    echo -e "⚠️ 请检查文件权限或手动检查文件内容\n" && exit 1
fi

rm -f "$tmpf2"



####################   zh-CN 本地化   ####################

echo -e "\n🌏 添加缺失的 zh-CN 翻译..."

pve_major_ver=$(echo "$pvever" | cut -d'.' -f1)

case "$pve_major_ver" in
    "8")
        # PVE 8.x: 为 Network traffic 图表添加中文 fieldTitles
        if ! grep -q "fields: \['netin', 'netout'\]" "$pvemanagerlib"; then
            echo -e "⛔ 未找到 Network traffic 的锚点, 操作终止!"
            echo -e "⚠️ 锚点 \"fields: ['netin', 'netout']\", 文件可能已更新或与当前版本不兼容\n" && exit 1
        else
            if grep -q "fieldTitles: \[gettext('传入'), gettext('发送')\]" "$pvemanagerlib"; then
                echo -e "Network traffic 的中文翻译已存在, 跳过该步骤 ➡️"
            else
                sed -i "s/^\( *\)fields: \['netin', 'netout'\],/&\n\1fieldTitles: [gettext('传入'), gettext('发送')],/" "$pvemanagerlib"
                if grep -q "fieldTitles: \[gettext('传入'), gettext('发送')\]" "$pvemanagerlib"; then
                    echo -e "已添加 PVE 8.x 缺失的翻译: 网络流量 图表上的 (传入)和(发送)按钮 ✅"
                else
                    echo -e "⛔ 检查对 Network traffic 部分的中文 fieldTitles 修改未生效!"
                    echo -e "⚠️ 请检查文件权限或手动检查文件内容\n" && exit 1
                fi
            fi
        fi

        # PVE 8.x: 为 Disk IO 图表添加中文 fieldTitles
        if ! grep -q "fields: \['diskread', 'diskwrite'\]" "$pvemanagerlib"; then
            echo -e "⛔ 未找到 Disk IO 的锚点, 操作终止!"
            echo -e "⚠️ 锚点 \"fields: ['diskread', 'diskwrite']\", 文件可能已更新或与当前版本不兼容\n" && exit 1
        else
            if grep -q "fieldTitles: \[gettext('读取'), gettext('写入')\]" "$pvemanagerlib"; then
                echo -e "Disk IO 的中文翻译已存在, 跳过该步骤 ➡️"
            else
                sed -i "s/^\( *\)fields: \['diskread', 'diskwrite'\],/&\n\1fieldTitles: [gettext('读取'), gettext('写入')],/" "$pvemanagerlib"
                if grep -q "fieldTitles: \[gettext('读取'), gettext('写入')\]" "$pvemanagerlib"; then
                    echo -e "已添加 PVE 8.x 缺失的翻译: 磁盘IO 图表上的 (读取)和(写入)按钮 ✅"
                else
                    echo -e "⛔ 检查对 Disk IO 部分的中文 fieldTitles 修改未生效!"
                    echo -e "⚠️ 请检查文件权限或手动检查文件内容\n" && exit 1
                fi
            fi
        fi
        ;;
    "9")
        echo -e "PVE 9.X 的 zh-CN 本地化将在未来的版本中支持, 跳过该步骤 ➡️"
        ;;
    *)
        echo -e "\n⚠️ 不支持的PVE版本($pvever), 跳过 zh-CN 本地化."
        ;;
esac



####################   调整页面高度   ####################

echo -e "\n🎚️ 调整修改后的页面高度..."

# 基于模型: 每行内容 17px, 每个模块段落间额外 7px 间距
calculate_height_increase() {
    local total_lines=0
    local module_count=0

    # itemId:cpupower(CPU能耗): 固定1行
    total_lines=$((total_lines + 1))
    module_count=$((module_count + 1))

    # itemId:cpufreq(CPU频率): 固定1行
    total_lines=$((total_lines + 1))
    module_count=$((module_count + 1))

    # itemId:sensors(传感器): 主信息固定1行
    total_lines=$((total_lines + 1))
    module_count=$((module_count + 1))
    # 使用 sensors 命令输出根据核心数量计算额外行数
    local core_temp_count=$(sudo sensors 2>/dev/null | grep -c '^Core')
    if [ "$core_temp_count" -gt 1 ]; then
        local sensor_core_lines=$(((core_temp_count + 4 - 1) / 4))
        total_lines=$((total_lines + sensor_core_lines))
    fi

    # itemId:nvme-status(NVMe硬盘): 固定4行每个
    local nvme_count=$(lsblk -d -o NAME | grep -c 'nvme[0-9]')
    if [ "$nvme_count" -gt 0 ]; then
        local nvme_lines=$((nvme_count * 4))
        total_lines=$((total_lines + nvme_lines))
        module_count=$((module_count + nvme_count))
    fi

    # itemId:sata_status(SATA硬盘): 无固定行
    module_count=$((module_count + 1))
    local sata_count=$(lsblk -d -o NAME | grep -c 'sd[a-z]')
    if [ "$sata_count" -gt 0 ]; then
        # 第1个SATA硬盘占2行, 后续每个占3行(含1行间距)
        local sata_lines=$((2 + (sata_count - 1) * 3))
        total_lines=$((total_lines + sata_lines))
    else
        # 不存在SATA硬盘时, 占用1行显示提示信息
        total_lines=$((total_lines + 1))
    fi

    # 根据模型计算总高度增量: (行数 * 17px) + (模块数 * 7px)
    local height_increase=$((total_lines * 17 + module_count * 7))
    echo $height_increase
}

# 获取计算出的高度增量
height_increase=$(calculate_height_increase)

# 基于基础高度(350px)计算新高度
new_height=$((350 + height_increase))

# 使用 sed 命令定位并更新 PVE.node.StatusView 的 height 属性
sed -i -E "/Ext.define\('PVE.node.StatusView'/,/height:/{s/height: *[0-9]+,/height: $new_height,/}" "$pvemanagerlib"
echo "页面高度经计算模型已动态调整为 ${new_height}px ✅"

if ! sed -n '/widget.pveDcGuests/,+15p' "$pvemanagerlib" | grep -q "textAlign: 'right'"; then
    ln=$(expr $(sed -n -e '/widget.pveDcGuests/=' $pvemanagerlib) + 10)
    sed -i "${ln}a\ textAlign: 'right'," "$pvemanagerlib"
fi
if ! sed -n '/widget.pveNodeStatus/,+15p' "$pvemanagerlib" | grep -q "textAlign: 'right'"; then
    ln=$(expr $(sed -n -e '/widget.pveNodeStatus/=' $pvemanagerlib) + 10)
    sed -i "${ln}a\ textAlign: 'right'," "$pvemanagerlib"
fi



####################   修改全部完成后重启服务   ####################

echo -e "\n🔁 等待服务 pveproxy.service 重启..."
timeout 10s systemctl restart pveproxy.service &> /dev/null
restart_status=$?
if [ $restart_status -ne 0 ]; then
    if [ $restart_status -eq 124 ]; then
        echo -e "\n⛔ 重启服务 pveproxy.service 超时 (timeout 10s)"
    else
        echo -e "\n⛔ 重启服务 pveproxy.service 失败 ($restart_status)"
    fi
    echo -e "\n⚠️ 请检查服务状态信息以排查问题\n"
    systemctl status pveproxy.service --no-pager
    echo && exit 1
fi

echo -e "\n✅ 修改完成, 请使用 Ctrl + F5 刷新浏览器 Proxmox VE Web 管理页面缓存\n"
