# Better Lag Compensation

A client-side **Don't Starve Together** mod for the that aims to add a better client-side lag compensation method. 
Mod is not fully develeped, it currently only supporst chopping/mining, collecting grass/twigs/crockpots and picking up the items and only upon pressing spacebar(quick action key).

[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=???) 

## How it works

Client can't allow you to perform some actions until server sent you a confirmation to your action (state 'busy' in game). Although, you can straight up ignore the server-client consensus by sending necessary packets directly after some delay. This is a pretty easy way of speeding up item pickup times.

There is a harder issue: resolving sprite updates on chopping/mining to make chopping/mining feel syncronized with your client. You wouldn't really feel the difference in the total time saved, but it just feels way smoother when you play the game yourself.

Fixing combat is planned and might be in reach of what is possible, although it's very hard to implement, the only perfect solution that I can see is emulating a server on your own client, which is pretty hard to do and would also put a decent strain on your hardware. Some not-so-perfect solutions have been tested, but I results were not satisfying.

## What is not possible

Don't starve together was not designed with proper syncronization. Any game state cannot be predicted perfectly. 

For example: you were trying to pickup an item, but server suddenly decided to strike a lightning at you. Your client thinks that you have picked up an item (client is actively trying to show you the 'future'), although because an 'unexpected event' happened your client can no longer pick up an item in the planned future and thus a 'small rollback' happens.

As you can see, it's simply impossible to fix lag compensation perfectly, since DST server has no implementation of 'commitment', nor does it support any 'plausability' client packets (fun fact: minecraft has a VERY non-strict server logic, clients can even fly).

A somewhat decent solution would be to make a server-side mod that would implement 'plausability layer', maybe something simillar to what GrimAntiCheat in Minecraft does.

## Installation

- **Steam:** subscribe on the [Workshop page](https://steamcommunity.com/sharedfiles/filedetails/?id=???), then enable the mod in **Mods**.
- **Manual:** copy the mod folder into `Don't Starve Together/mods/`.

This is a client-only mod. It works on any server and other players don't need it.

### Supporting me

I will try my best to make this mod work as best as it physically can, it would take time and I'm a bit exhausted from solving this issue right now.

You can support me monetarily by gifting me some skins on Steam (I'm actually quite fascinated, that this is a more world-wide accepted paying method than actual bank cards). You could also give a star on a github page or recommend the mod to your friends, feels pretty nice too.

### Contributing

This mod is currently opened for your suggestions(issues) and/or pull requests.
