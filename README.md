![DST](https://img.shields.io/badge/Don't%20Starve%20Together-client--side-blue)
![Status](https://img.shields.io/badge/status-beta-yellow)
![License](https://img.shields.io/badge/license-MIT-green)

# Better Lag Compensation

https://github.com/user-attachments/assets/61e0997e-c160-441a-b32d-b9c41a2e17a8

A client-side **Don't Starve Together** mod that adds a better client-side lag compensation method. It reduces the delay between your input and the visual result by predicting certain actions locally instead of waiting for the server to confirm them.

> ⚠️ **Status: Beta.** The mod currently supports a limited set of actions and is under development.

> **Keep the game's own Lag Compensation on** (Options → Lag Compensation: *Predictive*): the mod builds on it.
> Press **F8** in game to switch fast chains off and on, to compare.

[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3813222728) 

## How it works

Client can't allow you to perform some actions until server sent you a confirmation to your action (state 'busy' in game). Although, you can straight up ignore the server-client consensus by sending necessary packets directly after some delay. This is a pretty easy way of speeding up item pickup times.

There is a harder issue: resolving sprite updates on chopping/mining to make chopping/mining feel synchronized with your client. You wouldn't really feel the difference in the total time saved, but it just feels way smoother when you play the game yourself.

Fixing combat is planned and might be in reach of what is possible, although it's very hard to implement, the only perfect solution that I can see is emulating a server on your own client, which is pretty hard to do and would also put a significant strain on your hardware. Some not-so-perfect solutions have been tested, but results were not satisfying.

## What is not possible

Don't starve together was not designed with proper syncronization. **Game states can't be predicted perfectly.**

For example: you were trying to pickup an item, but server suddenly decided to strike a lightning at you. Your client thinks that you have picked up an item (client is actively trying to show you the 'future'), although because an 'unexpected event' happened your client can no longer pick up an item in the planned future and thus a 'small rollback' happens.

There is no way to fix this perfectly, because the DST server implements neither *commitment* nor *plausibility* checks on client packets. A proper fix would require a **server-side** mod that adds a plausibility layer, similar in spirit to GrimAntiCheat for Minecraft.

## Installation

- **Steam:** subscribe on the [Workshop page](https://steamcommunity.com/sharedfiles/filedetails/?id=3813222728), then enable the mod in **Mods**.
- **Manual:** copy the mod folder into `Don't Starve Together/mods/`.

This is a client-only mod. It works on any server and other players don't need it.

### Supporting me

I will try my best to make this mod work as best as it physically can, it would take time and I'm a bit exhausted from solving this issue right now.

If you'd like to support me: gift skins on Steam, star the repo, or share the mod.

### Contributing

This mod is currently open for your suggestions(issues) and/or pull requests.
