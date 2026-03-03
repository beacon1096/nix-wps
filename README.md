# Nix WPS Office

用于托管 WPS Office 及其配套软件的 Nix Flake。

## 使用方式

### 临时运行

```bash
nix run github:your-username/nix-wps
```

### 添加到系统配置

```nix
{
  environment.systemPackages = [
    (inputs.nix-wps.packages.x86_64-linux.wps365-cn)
  ];
}
```

### 开发使用

```bash
nix develop
```

## 更新 WPS Office

```bash
./pkgs/wps365-cn/update.sh
```

**注意**: 更新后需要手动验证新版本是否正常，并提交 `sources.nix` 的变更。

## 包含的软件

- **WPS365 Office Suite**: 12.1.2.24722 (Writer, Presentation, Spreadsheets, PDF)
- WPS 协作 (内置于主包)

## 支持的平台

- x86_64-linux

## License

WPS Office 使用专有许可证 (unfree)。
