# Backend

## Running it

```bash
npm install
cp .env.example .env
npm run dev
```

Then open <http://localhost:8000/api/notes>.

## What's in here

- `app.js`, the Express app. It serves the built frontend out of `dist/`, and
  handles `GET /health`, `GET /api/notes` and `POST /api/notes`. The notes are
  kept in memory.
- `server.js`, which starts the app on a port.
- `instance-name.js`, which finds the ECS task ID that the app shows on the
  page.
- `uploads.js`, which decides whether an attached file is written to
  `uploads/` or sent to S3, and turns a stored filename into a link the browser
  can open.
- `validation.js`, which checks the text of a note before it is saved.
- `.env.example`, the configuration this app expects. Copy it to `.env`, which
  is never committed.
