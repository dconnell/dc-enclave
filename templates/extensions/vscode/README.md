# Editor extension manifests

Editor extensions are declared separately from overlay `Containerfile.*` layers.
Copy these starter manifests into your team/user extension roots:

```
$DC_TEAM_DIR/extensions/vscode/
$DC_USER_DIR/extensions/vscode/
```

Templates shipped here:

- `all.txt`
- `nodejs.txt`

Example bootstrap flow:

```bash
mkdir -p "$DC_USER_DIR/extensions/vscode"
cp templates/extensions/vscode/*.txt "$DC_USER_DIR/extensions/vscode/"
dce config sync-vscode <project>
```

Use `dce extensions diff <project>` to inspect runtime drift and
`dce extensions capture` to curate additions back into manifests.
