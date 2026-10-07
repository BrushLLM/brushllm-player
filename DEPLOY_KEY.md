# Deploy key note

The local machine pushes via the SSH host alias `github-brushllm-player`
(see `~/.ssh/config`), using `~/.ssh/brushllm_player_deploy_v2` as the
deploy key. If pushes fail with `Permission denied (publickey)`, re-add
`~/.ssh/brushllm_player_deploy_v2.pub` as a **write** deploy key for this
repository.
