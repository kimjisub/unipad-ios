# UniPad iOS Project

<a href='https://apps.apple.com/us/app/unipad/id6760479102'><img alt='Download on the App Store' height="60px" src='https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83'/></a>

## Overview
UniPad is a performance-based rhythm game that enables connection with a launchpad and allows users to create their own beatmaps using the unique "unipack" format, fostering creativity and sharing within the community.

## Features
- Create custom beatmaps: Design your unique beatmaps and rhythms for various songs.
- Share beatmaps: Share your creations with other users in the community.
- Download community beatmaps: Access a diverse library of beatmaps created by others.
- In-app song library: Utilize the Public Domain licensed music library provided by the app.
- Frequent updates and bug fixes: Stay up-to-date with the latest features and improvements.

## Getting Started
### Prerequisites
To run this project locally, you need to have the following software installed on your computer:
1. Xcode (latest version)
2. iOS SDK (iOS 17.0 or higher)
3. Git (for cloning the repository)

### Installation
To set up this project on your local machine, follow these steps:
1. Clone the repository:
```bash
git clone https://github.com/Aezurolp/unipad-ios.git
cd unipad-ios
```
2. Open the project in Xcode:
   - Open `unipad.xcodeproj` in Xcode.
3. Build and run the project:
   - Select your target device or simulator.
   - Click the "Run" button (or press `Cmd + R`) in Xcode to build and run the app.

## Project Structure
The project is structured as follows:
- `unipad/App`: Application entry point and configuration.
- `unipad/Views`: UI screens and components.
- `unipad/Services`: Core services for MIDI, Audio, LED, and Theme processing.
- `unipad/Database`: SwiftData models and storage.

## Contributing
We welcome contributions to the UniPad project! To contribute, follow these steps:
1. Fork the repository.
2. Create a new branch for your feature or bug fix:
```bash
git checkout -b feature/your-feature-name
```
3. Commit your changes with descriptive commit messages:
```bash
git commit -m "Add your descriptive commit message here"
```
4. Push your changes to your fork:
```bash
git push origin feature/your-feature-name
```
5. Submit a pull request to the main repository, explaining your changes and their benefits.

## License
This project is licensed under the [GNU Lesser General Public License v2.1](LICENSE). See the LICENSE file for details.

## Acknowledgements
- [Kim Ji-Sub](https://github.com/kimjisub) - Original Creator and Lead Developer
- [UniPad Community](https://discord.gg/unipad) - For their valuable feedback, beatmaps, and support
