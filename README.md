# l2tp3 — Real L2TPv3 (Ethernet Pseudowire) Tunnel IR ↔ Foreign + Port Forward Manager

این پروژه یک **تونل واقعی L2TPv3 (لایه ۲ / Ethernet Pseudowire)** بین دو سرور ایجاد می‌کند:

- **ENTRY (ایران / IR):** سروری که کاربران به IP عمومی آن متصل می‌شوند  
- **EXIT (خارج / FR):** سروری که سرویس‌های اصلی شما (مثل V2Ray, ShadowSocks و …) روی آن اجراست  

سپس روی سرور **ایران (ENTRY)** عملیات **Port Forward** انجام می‌شود تا:

> کاربر فقط به **IP ایران** وصل شود  
> اما ترافیک واقعی از طریق تونل به **سرور خارج** منتقل گردد.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick Install](#quick-install)
- [Step-by-Step Setup](#step-by-step-setup)
- [Daily Usage](#daily-usage)
- [Port Management](#port-management)
- [Optional Tools](#optional-tools)
- [Uninstall](#uninstall)
- [Notes](#notes)

---

## Features

- ایجاد تونل واقعی **L2TPv3** با **UDP Encapsulation**
- ساخت اینترفیس شبکه مثل: `l2tpethX`
- اختصاص IP روی لینک تونلی (پیش‌فرض):
  - ENTRY → `10.200.0.1/30`
  - EXIT → `10.200.0.2/30`
- Port Forward روی سرور ایران:
  - `IR_PUBLIC:PORT → 10.200.0.2:PORT`
- بالا آمدن خودکار تونل بعد از ریبوت با **systemd**
- مدیریت کامل از طریق منوی تعاملی:
  - افزودن / حذف / مشاهده پورت‌ها
  - مشاهده وضعیت تونل
  - ریستارت تونل
  - ریستارت دوره‌ای خودکار
  - پاکسازی کش conntrack
  - حذف کامل اسکریپت

---

## Requirements

- VPS لینوکس (ترجیحاً Ubuntu / Debian)
- دسترسی `root` یا `sudo`
- پشتیبانی کرنل از ماژول‌های L2TP
- باز بودن UDP Port تونل بین دو سرور (پیش‌فرض: `17010`)

---

## Quick Install

روی **هر دو سرور (ایران و خارج)** اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/rahavard01/l2tp3-/main/l2tp3.sh | sudo bash -s -- install

##
پس از نصب، برای ورود به منوی مدیریتی:

sudo l2tp3


ترتیب صحیح راه‌اندازی :

نصب روی هر دو سرور

تنظیم EXIT (خارج) و گرفتن TOKEN

تنظیم ENTRY (ایران) با استفاده از TOKEN

تست تونل (Ping روی IP تونلی)

تست Port Forward (گوش دادن روی خارج و اتصال به ایران)

نکته مهم: تونل باید اول روی EXIT ساخته شود تا توکن تولید شود، بعد روی ENTRY توکن را وارد می‌کنید.

Step 1 — Install on Both Servers
روی هر دو سرور اجرا کنید:

curl -fsSL https://raw.githubusercontent.com/rahavard01/l2tp3-/main/l2tp3.sh | sudo bash -s -- install
Step 2 — Setup EXIT (Foreign Server) + Get TOKEN
روی سرور خارج:

sudo l2tp3
گزینه زیر را انتخاب کنید:

1) Setup EXIT (FR / foreign server)
اطلاعاتی که از شما می‌خواهد:

Public IP (EXIT): آی‌پی پابلیک سرور خارج

Public IP (ENTRY): آی‌پی پابلیک سرور ایران

UDP Port: پورت UDP تونل (پیش‌فرض: 17010)

Tunnel ID / Session ID: پیش‌فرض 1000 (در صورت نیاز تغییر دهید)

MTU: پیش‌فرض 1380

در پایان یک TOKEN نمایش داده می‌شود:

✅ آن را کامل کپی کنید (برای مرحله بعد لازم است)

Step 3 — Setup ENTRY (Iran Server) Using TOKEN + Add Ports
روی سرور ایران:

sudo l2tp3
گزینه زیر را انتخاب کنید:

2) Setup ENTRY (IR / Iran server)
سپس:

TOKEN را Paste کنید

در صورت نیاز، لیست پورت‌هایی که می‌خواهید فوروارد شوند را وارد کنید

فرمت صحیح پورت‌ها:

هر پورت با /tcp یا /udp

چند پورت با کاما جدا شود

مثال:

443/tcp,2053/tcp,2087/tcp,3478/udp
پس از پایان:

تونل برقرار می‌شود

Port Forward روی سرور ایران اعمال می‌شود

مقصد فوروارد: 10.200.0.2 (سرور خارج روی تونل)

Step 4 — Test Tunnel Connectivity (Must Pass)
روی سرور ایران:

ping -c 3 10.200.0.2
✅ اگر پاسخ دریافت شد یعنی تونل سالم است.

برای مشاهده وضعیت کامل:

sudo l2tp3 status
Step 5 — Test Port Forward (End-to-End)
روی سرور خارج (برای تست TCP روی 443):

sudo apt-get install -y netcat-openbsd
sudo nc -lvnp 443
حالا از یک سیستم بیرونی (یا حتی از سرور ایران):

nc -vz IP_IR 443
✅ اگر اتصال در خروج (EXIT) دیده شد یعنی فوروارد درست کار می‌کند.

Daily Usage
Tunnel Status
sudo l2tp3 status
Restart Tunnel
sudo l2tp3 restart
Port Management
List Ports
sudo l2tp3 list-ports
Add Port
sudo l2tp3 add-port 443/tcp
sudo l2tp3 add-port 3478/udp
Delete Port
sudo l2tp3 del-port 2053/tcp
Re-Apply Rules
sudo l2tp3 apply
Optional Tools
Auto Restart (Periodic)
مثال: هر 15 دقیقه ریستارت خودکار

sudo l2tp3 enable-autorestart 15
غیرفعال کردن:

sudo l2tp3 disable-autorestart
Conntrack Cache Cleanup ⚠️
فعال‌سازی پاکسازی دوره‌ای (مثال: هر 30 دقیقه):

sudo l2tp3 enable-cache 30
غیرفعال کردن:

sudo l2tp3 disable-cache
پاکسازی دستی:

sudo l2tp3 flush-cache
Uninstall
حذف کامل:

sudo l2tp3 uninstall
Notes
اگر تونل برقرار شد ولی برخی پورت‌ها درست فوروارد نشدند، یک‌بار apply اجرا کنید:

sudo l2tp3 apply
اگر روی شبکه‌های خاص NAT/فایروال دارید، مطمئن شوید UDP Port تونل (پیش‌فرض 17010) بین دو سرور باز است.

مقدار MTU روی کیفیت و پایداری تونل اثر دارد؛ اگر پکت‌لاست دیدید، MTU را کاهش دهید (مثلاً 1360 یا 1340).
