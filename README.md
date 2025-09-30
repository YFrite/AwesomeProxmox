# 🚀 Awesome Proxmox

A curated collection of **useful scripts, tools, and tips** for managing **Proxmox VE** environments.  
This repository aims to simplify common administrative tasks and provide handy utilities for Proxmox administrators.

---

## 📂 Directory Structure
```
scripts/
├── management/
│   └── lxc-shrink-lv.sh    # Script to shrink LXC container disk volumes safely
```
Currently, the repository contains:

### 📝 `scripts/management/lxc-shrink-lv.sh`

A **bash script** to safely **shrink the disk size of LXC containers** in Proxmox VE.  
It handles:

- 🛑 Stopping the container if running
- 💾 Creating optional LVM snapshots before shrinking
- ✅ Running filesystem checks (`e2fsck`)
- 📏 Resizing the filesystem (`resize2fs`)
- 🔧 Reducing the logical volume (`lvreduce`)
- 🗂 Updating the container configuration in `/etc/pve/lxc/<CTID>.conf`
- ▶️ Starting the container after completion
- 📦 Maintaining backups and snapshot info

> [!WARNING]  
> Works with **ext2/3/4 filesystems**. XFS or other filesystems require different procedures.

---

## 🤝 Contributing

Feel free to contribute!

* Add new scripts or utilities
* Suggest improvements for existing scripts
* Share tips and tricks for Proxmox administration

Please submit **pull requests** or **open issues** for discussion.

