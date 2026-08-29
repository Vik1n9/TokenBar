# TokenBar

> **Unofficial, community-built tool. Not affiliated with, endorsed by, or
> sponsored by any of the services it reads from.** All product names and
> trademarks are the property of their respective owners. See
> [Trademarks and disclaimer](#trademarks-and-disclaimer).

A small macOS menu bar app that shows how much allowance or credit each of your
AI API accounts has left, without opening a console in a browser.

One menu bar item, showing one account at a time and rotating every minute:

```
Q 42% · 2d        →  a minute later  →        D ¥110.00
```

That reads: 42% of the QwenCloud 7-day allowance left, resetting in 2 days; then
¥110.00 of DeepSeek API credit remaining. The reading turns red when that account
is running low, and grey with a `⚠` when its last refresh failed.

Rotating rather than listing every account side by side keeps the menu bar
footprint at one reading no matter how many accounts you add. The rotation holds
still while the menu is open, so the title cannot change while you are reading.

Click it and **every** account is shown at once, one card each. The drop-down
stays deliberately short — what is left, and when that changes:

```
Q  QwenCloud Token Plan
   7-day allowance              42% left
   ▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░
   Resets in 2d
   Open Console
   Sign Out
───────────────────────────────────────
D  DeepSeek API
   Balance                       ¥110.00
   Off-peak (50% off) · peak in 4h
   Open Usage Page
```

## Supported accounts

| | Service | Credential | Shows |
|---|---|---|---|
| `Q` | QwenCloud Token Plan | console sign-in | remaining 7-day allowance, reset countdown |
| `D` | DeepSeek API | API key | balance, peak/off-peak rate band |

Adding another service is a folder under `Sources/TokenBar/Providers/` plus one
line in `ProviderRegistry`.

## A note on DeepSeek spend figures

The drop-down shows the balance, not a spend history: the numbers behind
"spent today" are estimates, and a menu full of estimates is harder to read than
one number that is exact. Today's spend is still available as an optional second
figure in the menu bar title, from the DeepSeek settings tab.

Where that figure comes from: DeepSeek publishes a balance endpoint but no usage
endpoint that every account can reach. TokenBar tries the undocumented
`/v1/usage` once; when the account has it, the figure comes from there and is
exact. When it does not (many keys get a 404), TokenBar falls back to a
**balance ledger**: it records the balance on each refresh and treats each drop
as spending, adding back any top-up that happened in the same interval. Granted
credit that vanishes on its own is treated as an expiry, not as usage, and is
excluded. That fallback is an estimate by construction — its resolution is your
refresh interval, and it cannot attribute spend to a model.

Wallets in different currencies are never converted and never added together.
There is no exchange rate anywhere in this app. If you ask for a currency the
account does not hold, you get the real wallet prefixed with its ISO code
(`CNY ¥70.16`) rather than a converted number.

## Install

1. Download `TokenBar-<version>.dmg` from the
   [latest release](../../releases/latest) and open it.
2. Drag `TokenBar.app` onto the `Applications` shortcut, then eject the image.
3. **First launch only** — the app is not notarized by Apple (that requires a
   paid Developer ID), so macOS quarantines it. Clear the flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/TokenBar.app
   ```

   Then open it normally. You can also right-click the app → **Open** → **Open**.

## Setup

Open **Settings…** from any menu bar item.

- **General** — refresh interval, launch at login, which accounts appear in the
  menu bar, and update checking. Hiding an account drops it from the title and
  stops polling it.
- **QwenCloud Token Plan** — sign in once through the console window.
- **DeepSeek API** — paste an API key and press **Validate & Save**. The key is
  checked against the balance endpoint before it is stored. Optionally set a
  custom endpoint, a preferred currency, a low-balance warning threshold, and
  whether the menu bar shows today's spend next to the balance.

Your DeepSeek API key is stored in the **login keychain**, never in preferences,
the ledger file, or any log.

## Updates

Once a day TokenBar asks GitHub whether a newer release exists. If one does, the
drop-down grows an **Update available: x.y.z…** row and a notification is posted
once for that version. Clicking the row opens the release page in your browser —
**nothing is downloaded, replaced or installed for you**; updating stays a
manual drag into `Applications`, exactly like the first install.

Pre-releases and drafts are ignored. Turn the whole thing off, or check on
demand, under **Settings → General → Updates**.

## Privacy

- Credentials never leave your machine. The API key lives in the keychain; the
  Qwen session lives in the app's own WebKit cookie store.
- The only network traffic is to the endpoints of the accounts you configured,
  plus one request a day to GitHub's public release API when update checking is
  on. That request carries no account data — turn it off in Settings if you
  would rather it never happened.
- No analytics, no telemetry, no third-party tracking.
- The spend ledger is a plain JSON file at
  `~/Library/Application Support/TokenBar/deepseek-ledger.json`. It holds
  timestamps and amounts only.

## Trademarks and disclaimer

TokenBar is an independent project. It is not affiliated with, authorized by,
endorsed by, sponsored by, or supported by any of the services it reads from.

Service names appear in this README, in the Settings tab titles, and in API
endpoint URLs solely to identify which third-party service each part of the app
talks to. No ownership of, or right to, any of those marks is claimed, and no
affiliation, partnership, certification or endorsement is implied.

"Qwen", "QwenCloud", "Alibaba Cloud" and "Aliyun" are trademarks of Alibaba
Group Holding Limited. "DeepSeek" is a trademark of Hangzhou DeepSeek Artificial
Intelligence Co., Ltd. See [NOTICE](NOTICE) for the full statement and for
third-party source attribution.

## License

[MIT](LICENSE). The license covers this project's own source code only; it
grants no rights to any third-party trademark, service, API, or content.
