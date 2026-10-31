# Glam & Glow — Setup

How the pieces fit together:

```
Website (GitHub Pages, plain HTML/JS)
   │  supabase-js  ──────────────►  Supabase
   │                                 ├─ Auth      sign up / sign in / password reset
   │                                 ├─ Postgres  the dermalytics database + functions
   │                                 └─ Storage   skin-images (private)
   │
   └─ photo + sign-in token ───►  Dermalytics API (Railway, FastAPI + .keras model)
                                     └─ stores photo + result in Supabase
```

| File | What it is |
|---|---|
| `database/schema.sql` | structure of the local database (export) |
| `database/dermalytics_full.sql` | structure + data — **not committed to git** |
| `database/supabase_setup.sql` | run once in Supabase: accounts, booking, tracking, security |
| `js/config.js` | Supabase URL + anon key + API URL |
| `js/site.js` | shared helpers (session, dates, header button) |
| `js/tracker.js` | visit / page / click tracking |
| `js/booking.js` | calendar + free times picker |
| `dermalytics-api/` | the model API for Railway |

---

## 1. Create the Supabase project

1. Sign up at supabase.com → **New project** → region **Frankfurt (eu-central-1)**. Save the database password somewhere safe.
2. **Authentication → Sign In / Providers → Email**: turn **Confirm email OFF** (no verification).
3. **Authentication → URL Configuration**:
   - Site URL: your GitHub Pages address (later), e.g. `https://USERNAME.github.io/REPO/`
   - Redirect URLs: add `http://127.0.0.1:5500/**` and `https://USERNAME.github.io/REPO/**` (used by the password-reset email)

## 2. Copy the database into Supabase

In Supabase click **Connect** → **Session pooler** and copy the URI (it looks like
`postgresql://postgres.abcd...:[YOUR-PASSWORD]@aws-0-eu-central-1.pooler.supabase.com:5432/postgres`).
Remove `:[YOUR-PASSWORD]` from it — psql will ask for the password instead.

```bash
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" "PASTE_URI_HERE" -v ON_ERROR_STOP=1 --single-transaction -f "database\dermalytics_full.sql"
```

```bash
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" "PASTE_URI_HERE" -v ON_ERROR_STOP=1 --single-transaction -f "database\supabase_setup.sql"
```

Both must end without an `ERROR` line. With `--single-transaction`, a failed run changes nothing, so it can simply be run again after fixing the cause.

## 3. Connect the website

**Project Settings → API**: copy the **Project URL** and the **anon public** key into `js/config.js`.
Never put the `service_role` key in the website.

Try it locally (from the project folder), then open http://127.0.0.1:5500 :

```bash
python -m http.server 5500 --bind 127.0.0.1
```

## 4. Deploy the Dermalytics model API (Railway)

1. Put the model in `dermalytics-api/model/dermalytics.keras`.
2. Create `dermalytics-api/model/classes.json` with the class names **in the training order**, e.g. `["Acne", "Eczema", "Rosacea"]`.
3. Check `preprocess()` in `dermalytics-api/main.py` matches the notebook (image scaling).
4. Railway → **New Project** → deploy the `dermalytics-api` folder (GitHub repo with *Root Directory* = `dermalytics-api`, or the Railway CLI `railway up` from inside that folder).
5. Railway → **Variables**: copy them from `dermalytics-api/.env.example` and fill them in
   (`SUPABASE_SERVICE_KEY` = Supabase **service_role** key — secret, only here).
6. Railway → **Settings → Networking → Generate Domain**, then paste that URL into `DERMALYTICS_API_URL` in `js/config.js`.

## 5. Publish on GitHub Pages

1. Install Git, create a GitHub repository, push this folder (`.gitignore` keeps the data dump out).
2. Repository → **Settings → Pages** → Deploy from branch `main`, folder `/ (root)`.
3. Add the Pages address to Supabase redirect URLs (step 1.3) and to Railway `ALLOWED_ORIGINS`.

---

## Notes

- **Password-reset emails**: Supabase's built-in email sender only delivers to members of the Supabase project team and only a few per hour. Fine for a demo; for real customers, add an SMTP provider under Authentication → Emails.
- **Booking rules** live in the database (`system_settings`, `working_hours`, `clinic_closures`). Changing e.g. `BUFFER_MINUTES` there changes the website immediately.
- **Power BI** reads `web_sessions`, `page_views` and `website_interactions` (plus the business tables) through the Session pooler connection.
