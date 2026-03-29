# paymenter-install-debian

`paymenter-install-debian` is a hardened installer for running [Paymenter](https://github.com/paymenter/paymenter) on Debian- and Ubuntu-based servers.

## English

### What it does

- Installs PHP 8.3 and the required PHP extensions
- Installs MariaDB, Nginx, Redis, Composer, and cron dependencies
- Supports both Debian and Ubuntu package source setup
- Configures Paymenter `.env` values and updates `app_url`
- Sets up Nginx, cron, and a systemd queue worker
- Optionally installs SSL with Certbot for domain-based deployments
- Prompts for the first admin account during installation

### Highlights

- Better error handling with `set -Eeuo pipefail` and a clear failure trap
- Works on Debian as well as Ubuntu
- Uses PHP 8.3
- Avoids fragile `mysql_secure_installation` automation
- Writes environment values idempotently
- Prevents duplicate cron entries on reruns
- Updates `APP_URL` and Paymenter `app_url` after SSL is enabled
- Reuses an existing Paymenter directory when rerun

### Supported systems

- Debian 12 and similar Debian-based systems
- Ubuntu 22.04, 24.04, and similar Ubuntu-based systems

### Usage

```bash
git clone https://github.com/OvO-nei/paymenter-install-debian.git
cd paymenter-install-debian
chmod +x install.sh
sudo ./install.sh
```

### Prompts

The installer asks for:

- Your domain name or server IP
- The Paymenter database password
- The first admin user's name, email, and password
- Whether SSL should be installed

### Notes

- SSL issuance requires a real domain name. The script skips Certbot automatically if you enter an IP address.
- The installer assumes a fresh or mostly clean server for the smoothest result.
- Paymenter will be installed into `/var/www/paymenter`.

### Validation

The current script has been checked with:

- `bash -n install.sh`
- `app:settings:change`
- `app:cron-job`
- `app:user:create`

## 日本語

### 概要

`paymenter-install-debian` は、[Paymenter](https://github.com/paymenter/paymenter) を Debian 系および Ubuntu 系サーバーへ導入するための安定化インストーラーです。

### できること

- PHP 8.3 と必要な PHP 拡張をインストール
- MariaDB、Nginx、Redis、Composer、cron 関連を導入
- Debian と Ubuntu の両方でパッケージソースを適切に設定
- Paymenter の `.env` と `app_url` を自動設定
- Nginx、cron、systemd の queue worker を自動構成
- ドメイン利用時は Certbot による SSL 設定に対応
- インストール中に最初の管理者アカウントを作成

### 特徴

- `set -Eeuo pipefail` と trap によるエラー処理を追加
- Ubuntu だけでなく Debian にも対応
- PHP 8.3 を使用
- 壊れやすい `mysql_secure_installation` 自動化を使わない
- `.env` の値を再実行時も安全に更新
- cron の重複登録を防止
- SSL 設定後に `APP_URL` と Paymenter の `app_url` を再更新
- 再実行時は既存の Paymenter ディレクトリを再利用

### 対応環境

- Debian 12 および同系統の Debian ベース環境
- Ubuntu 22.04、24.04 および同系統の Ubuntu ベース環境

### 使い方

```bash
git clone https://github.com/OvO-nei/paymenter-install-debian.git
cd paymenter-install-debian
chmod +x install.sh
sudo ./install.sh
```

### 入力項目

インストーラーは次の内容を確認します。

- ドメイン名またはサーバーの IP
- Paymenter 用データベースパスワード
- 最初の管理者ユーザーの氏名、メールアドレス、パスワード
- SSL を導入するかどうか

### 注意点

- SSL の自動発行には実在するドメイン名が必要です。IP アドレスを入力した場合、Certbot は自動的にスキップされます。
- できるだけ新規に近いサーバーでの実行を推奨します。
- Paymenter は `/var/www/paymenter` にインストールされます。

### 確認済み項目

- `bash -n install.sh`
- `app:settings:change`
- `app:cron-job`
- `app:user:create`

## License

MIT
