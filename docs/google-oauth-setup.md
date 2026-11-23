# Google OAuth setup for Broadcast

Broadcast reads your Google Calendar through the Google Calendar API. Do this once in
Google Cloud Console to get a client ID and secret for your own copy. It takes about
ten minutes. Nothing here costs money.

## How sign-in works

Broadcast uses the flow Google recommends for macOS desktop apps:

- a **Desktop app** OAuth client,
- the system browser for the Google consent page,
- a **loopback redirect** (`http://127.0.0.1:<random port>/oauth2redirect`) that the app
  listens on briefly while you sign in,
- PKCE (S256).

Google no longer supports custom URL schemes for this, so you **do not** register a
redirect URI or a URL scheme anywhere. Desktop clients accept any loopback port.

The app asks for two read-only scopes:

| Scope | Why |
| --- | --- |
| `https://www.googleapis.com/auth/calendar.events.readonly` | Read upcoming events |
| `https://www.googleapis.com/auth/calendar.calendarlist.readonly` | List your calendars, and show your account email (your primary calendar's ID) |

## 1. Create a project

1. Open <https://console.cloud.google.com/> and sign in with the Google account whose
   calendar you want to use.
2. In the project picker at the top, choose **New project**. Name it, for example,
   `Broadcast`. Leave the organisation as is. Click **Create** and switch to the project.

## 2. Enable the Google Calendar API

1. Go to **APIs & Services → Library**.
2. Search for **Google Calendar API**, open it and click **Enable**.

## 3. Configure the consent screen (Google Auth Platform)

1. Go to **APIs & Services → OAuth consent screen** (this opens **Google Auth Platform**).
   If asked, click **Get started**.
2. **App information:** app name `Broadcast`, user support email = your address.
3. **Audience:** choose **External**. (Choose **Internal** only if your account is in a
   Google Workspace organisation and you want to limit it to that organisation.)
4. **Contact information:** your address. Agree to the policy and click **Create**.
5. Open **Audience**. Make sure **Publishing status** is **Testing**. Under
   **Test users**, click **Add users** and add your own Google address. Only test users
   can sign in while the app is in testing.
6. Open **Data Access** → **Add or remove scopes**. Filter for `calendar` and tick:
   - `.../auth/calendar.events.readonly`
   - `.../auth/calendar.calendarlist.readonly`

   Click **Update**, then **Save**. (These scopes are what the app requests anyway; listing
   them here keeps the consent screen honest.)

> **Testing mode limit:** while the publishing status is *Testing*, Google expires refresh
> tokens after **7 days**. Broadcast then shows you as signed out; sign in again in
> Settings. To avoid this you would have to publish the app, which for these scopes
> requires Google's verification. That is not needed for personal use.

## 4. Create the OAuth client

1. Open **Clients** (Google Auth Platform) → **Create client**.
2. **Application type: Desktop app.** Not *iOS*, not *Web application*.
3. Name: `Broadcast macOS`. Click **Create**.
4. A dialog shows the **Client ID** and **Client secret**. Copy both, or click
   **Download JSON**. You can open the client again later to see the ID. Google shows the
   full secret only when you create it, so if you lose it, add a new secret to the client.

The Desktop client secret is not really secret (Google says desktop apps cannot keep
secrets confidential, which is why PKCE is used). Still keep it out of git, as below.

## 5. Put the values where the app expects them

Create `Config/Secrets.xcconfig` in the repository root. It must never be committed.

First make sure git ignores it. The repository's root `.gitignore` must contain the line
`/Config/Secrets.xcconfig`; add it if it is missing, then check:

```sh
git check-ignore -v Config/Secrets.xcconfig   # must print the matching .gitignore rule
```

If that prints nothing, the file is **not** ignored. Fix `.gitignore` before you create the
file, so `git add -A` cannot stage your credentials. Then create it:

```xcconfig
// Config/Secrets.xcconfig — DO NOT COMMIT
GOOGLE_CLIENT_ID = 1234567890-abcdefghijklmnop.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET = GOCSPX-your-secret-here
```

Copy the values exactly, with no quotes. If the secret contains `//`, write it as `/$()/`,
because xcconfig treats `//` as the start of a comment.

That is all you need. There is **no redirect URI or URL scheme to configure**: the redirect
is a loopback address chosen at sign-in time.

How the app uses these values, for reference:

- The app's Info.plist has `GoogleClientID = $(GOOGLE_CLIENT_ID)` and
  `GoogleClientSecret = $(GOOGLE_CLIENT_SECRET)`.
- At launch, `GoogleAuthConfiguration(bundle: .main)` reads them. It returns `nil` when the
  client ID is missing, which the app shows as "Google sign-in is not configured".
- The app's sandbox entitlements include `com.apple.security.network.client` (calls to
  Google) and `com.apple.security.network.server` (the loopback listener used only during
  sign-in).

## 6. Sign in

Build and run Broadcast, open **Settings → Google Calendar → Sign in**. Your browser opens
Google's consent page:

1. Choose the account you added as a test user.
2. Google warns **"Google hasn't verified this app"**. That is expected in testing mode:
   click **Continue**.
3. Leave both calendar permissions ticked and click **Continue**. If you untick one, the
   app reports which permission is missing and asks you to sign in again.
4. The browser says Google has sent the response to the app. Close the tab and go back to
   Broadcast. Settings shows your email address if sign-in finished, or an error (for
   example a missing permission) if it did not.

Tokens are stored in your login Keychain under the service `GoogleCalendarKit`.
**Sign out** in Settings revokes access at Google and deletes them. You can also remove
access at <https://myaccount.google.com/permissions>.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Error 403: access_denied` / "has not completed the Google verification process" | Your account is not a test user. Add it under **Audience → Test users**. |
| `Error 401: invalid_client` | The client ID or secret in `Secrets.xcconfig` is wrong, or the client is not of type **Desktop app**. |
| `Error 400: redirect_uri_mismatch` | The client is a *Web application* client. Create a **Desktop app** client instead. |
| Calendar API answers `403 accessNotConfigured` | Enable the Google Calendar API in this project (step 2). |
| Signed out after about a week | Expected in testing mode (7-day refresh tokens). Sign in again. |
| The browser never reaches the "response sent to the app" page | Another app or firewall blocked `127.0.0.1`, or the app lacks the `network.server` entitlement. |
