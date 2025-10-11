# SwiftBundle


## Instructions

### Build the executable

```sh
swiftc main.swift AppDelegate.swift -o SwiftClipBundle -framework Cocoa
```


### Make a macOS .app package

1. Create the following dir structure

```
swiftBundle.app
└── Contents
    ├── Info.plist
    ├── MacOS
    │   └── SwiftClipBundle
    └── Resources
        └── AppIcon.icns
```

with the executable under `MacOS` dir

2. Use resulting package as an app