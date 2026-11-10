# Releasing the TonePerfect SDKs (0.3.0)

Owner-only steps. Nothing here has been run: no package is published, no registry account was created, and this
branch (`release/0.3.0`) is not pushed. All six clients carry version 0.3.0.

State on 2026-11-10: npm `toneperfect` 0.1.0 and pub.dev `toneperfect` 0.1.1 are ours; PyPI `toneperfect`,
RubyGems `toneperfect` and Packagist `toneperfect/toneperfect` are unclaimed (404); the Go module had a placeholder
path. The GitHub repository `vm542/toneperfect-sdk` is public and still at the first 0.1.0 commit.

## 0. Check, then push the repository and the tags

```sh
python3 testing/run_readme_examples.py                       # every README block against the mock (live rules)
python3 testing/run_readme_examples.py --gateway 1110        # and against the 2026-11-10 gateway behaviour
TONEPERFECT_API_KEY=tp_test_... python3 testing/run_readme_examples.py --live   # live API, test key, 1 request / 4 s
(cd python && PYTHONPATH=src python3 -m unittest discover -s tests) && (cd node && npm test) \
  && (cd dart && dart pub get && dart analyze && dart test) && (cd ruby && ruby -Ilib -Itest test/test_client.rb) \
  && (cd go && go vet ./... && go test ./...) && composer validate --strict && php php/tests/run.php

git checkout main && git merge --ff-only release/0.3.0
git tag -a v0.3.0 -m "TonePerfect SDKs 0.3.0"           # Packagist reads v0.3.0
git tag -a go/v0.3.0 -m "TonePerfect Go module 0.3.0"   # the Go module lives in go/, so its tags are go/vX.Y.Z
git push origin main v0.3.0 go/v0.3.0
```

Packagist and Go read GitHub, so this push comes first.

## 1. npm (`toneperfect`, already ours)

```sh
cd node
npm test
npm pack --dry-run          # 11 files, toneperfect-0.3.0.tgz
npm publish --access public # add --otp=123456 if the account uses 2FA
npm view toneperfect version   # expect 0.3.0
```

## 2. PyPI (`toneperfect`, unclaimed: needs the owner's PyPI account and an API token)

```sh
cd python
python3 -m venv .venv && .venv/bin/pip install build twine
.venv/bin/python -m build                 # dist/toneperfect-0.3.0.tar.gz and -py3-none-any.whl
.venv/bin/twine check dist/*
TWINE_USERNAME=__token__ TWINE_PASSWORD="pypi-..." .venv/bin/twine upload dist/*
pip index versions toneperfect            # expect 0.3.0
```

## 3. RubyGems (`toneperfect`, unclaimed: needs a RubyGems account with MFA, the gemspec requires it)

```sh
cd ruby
gem build toneperfect.gemspec             # toneperfect-0.3.0.gem
gem signin                                # once
gem push toneperfect-0.3.0.gem            # asks for the MFA code
gem list -r toneperfect                   # expect toneperfect (0.3.0)
```

## 4. Packagist (`toneperfect/toneperfect`, unclaimed: needs a Packagist account linked to GitHub)

`composer.json` is at the repository root (Packagist reads only the root) and autoloads `php/src/TonePerfect.php`.
After step 0 pushed tag `v0.3.0`:

1. https://packagist.org/packages/submit → Repository URL `https://github.com/vm542/toneperfect-sdk` → Check → Submit.
2. On the package page, enable the GitHub service hook (or `Settings → Webhooks` on GitHub with Packagist's URL)
   so later tags update it.
3. Check: `composer show -a toneperfect/toneperfect` lists `v0.3.0`.

## 5. pub.dev (`toneperfect`, already ours)

```sh
cd dart
dart pub get && dart analyze && dart test
dart pub publish --dry-run                # "Package has 0 warnings" from a clean checkout
dart pub publish
```

## 6. Go (`github.com/vm542/toneperfect-sdk/go`)

No account. Step 0 pushed `go/v0.3.0`; ask the proxy to fetch it so pkg.go.dev indexes it:

```sh
GOPROXY=https://proxy.golang.org go list -m github.com/vm542/toneperfect-sdk/go@v0.3.0
```

Then https://pkg.go.dev/github.com/vm542/toneperfect-sdk/go shows 0.3.0 within minutes.

## 7. The website

The site serves the same Python and Node.js files under https://api.toneperfect.app/sdk/ (synced from this
repository by `scripts/sync-sdk.mjs` in `toneperfectapi`). Once npm and PyPI show 0.3.0, release the prepared
site commit that switches `/sdk/` and the docs to `pip install toneperfect` / `npm install toneperfect`.

## Next release

Bump the version in `python/pyproject.toml` and `python/src/toneperfect.py` (`__version__`), `node/package.json`
and `node/index.cjs` (`VERSION`), `dart/pubspec.yaml` and `dart/lib/toneperfect.dart` (`toneperfectVersion`),
`ruby/lib/toneperfect.rb` (`VERSION`), `php/src/TonePerfect.php` (`VERSION`) and `go/toneperfect.go` (`Version`);
add a CHANGELOG entry; tag `vX.Y.Z` and `go/vX.Y.Z`.
