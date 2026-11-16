# Whale landing page

A static landing page with the actual Whale 0.4.0 DMG included. No packages,
API keys, build step, or backend are required for the website.

## Deploy on Vercel

If importing this repository, set **Root Directory** to `landing-page`.
Use **Framework Preset: Other**. The included `vercel.json` sets the output
directory to `public` and leaves the build command empty.

Alternatively, deploy this directory with the Vercel CLI:

```sh
cd landing-page
vercel
```

After checking the preview, publish using `vercel --prod` and attach your domain
in the Vercel project's Domains settings. Ensure the production site is publicly
accessible so downloads do not require a Vercel login.

The download is served directly from your deployed domain:

```text
/downloads/Whale-0.4.0-apple-silicon.dmg
```

The product and website are branded Whale. WhaleNote is the intended domain
name only. The release is ad-hoc signed,
unnotarized, and supports Apple Silicon Macs with macOS 15 or later. Users need
their own OpenAI API key for AI processing. The sample meeting in the page is
illustrative, not user data or a screenshot of an actual meeting.

## Local preview

```sh
python3 -m http.server 4173 --directory landing-page/public
```

Open http://localhost:4173 from the repository root. If running inside this
directory instead, use `--directory public`.

## Update the download

1. Run `./scripts/build-dmg.sh` from the repository root.
2. Copy the new DMG and its `.sha256` file from `dist/` to
   `landing-page/public/downloads/`.
3. Update the download links, version, file size, and platform text in
   `public/index.html`. Keep published version filenames immutable.
4. Redeploy the landing page. Retain older files if their download URLs should
   continue to work.

The DMG is intentionally included in this website directory, even though the
app project's `dist/` directory is ignored by Git. Include the website's
downloads directory when committing or uploading the site.

## Automatic app updates

Whale 0.3.0 includes Sparkle. It checks `https://whalenote.app/updates/appcast.xml`,
downloads signed updates automatically, and installs on quit. Users can turn this
off in Settings or use Whale → Check for Updates. Active recording/processing
prevents update checks and postpones an updater-initiated relaunch.

For each release:

1. Increment both `CFBundleVersion` (an integer) and `CFBundleShortVersionString`
   in `Resources/Info.plist`. Never reuse a published build number.
2. Run `./scripts/build-release.sh` from the repository root on this Mac.
3. Deploy `landing-page/` to Vercel with the production domain `whalenote.app`.
   The script refreshes the download link, DMG, checksum, and signed appcast.
4. Test an older updater-enabled app against the deployed feed before announcing
   the release. Verify installation, relaunch, and preservation of meetings/settings.

The private Ed25519 signing key lives in macOS Keychain under account
`app.whale.desktop`. Only the public key is committed. Keep a secure backup of the
private key outside the repository and website; losing it prevents updates to
existing unsigned installations. Sparkle's `generate_keys --account app.whale.desktop`
can display the public key; its `-x` option exports a private backup to a path you
choose. Never put that backup in `public/` or commit it.

Automatic updates do not notarize the app. First-time installs may still need
Apple's Open Anyway flow. Users on versions before 0.3.0 need one manual install
to receive the updater. The feed serves Apple Silicon builds only.
