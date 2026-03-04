# my_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Android Release (Google Play)

1) Set unique application ID and app name

- Edit `android/app/build.gradle.kts`:
  - `namespace` and `defaultConfig.applicationId` → your package (e.g. `com.yourcompany.photoremn`)
- Edit `android/app/src/main/AndroidManifest.xml`:
  - `android:label` → your app name

2) Create a release keystore

```
keytool -genkeypair -v -keystore ~/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

3) Add signing config

- Create `android/key.properties` (not tracked by Git):

```
storeFile=/Users/yourname/upload-keystore.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=upload
keyPassword=YOUR_KEY_PASSWORD
```

- The Gradle script reads this file automatically and signs release builds.

4) Build for Play Store

```
flutter build appbundle --release
```

Upload the generated `.aab` in `build/app/outputs/bundle/release/` to Google Play Console.

5) Permissions

- This app requests `READ_MEDIA_IMAGES` (Android 13+) and legacy read/write for API ≤ 32.
- `MANAGE_EXTERNAL_STORAGE` was removed to comply with Play policy. Add it back only if your app truly needs broad file access and you can justify it during review.

6) Store listing checklist

- Screenshots, short/long descriptions, privacy policy URL
- Data safety form, content rating
- Internal testing → production rollout

## 権限の説明文（コピペ用）

アプリは「写真と動画」へのアクセスを使います。以下は Google Play Console の権限申告と、アプリ内での説明に使用できる文面です。

- 権限: 写真と動画（Android 13+: `READ_MEDIA_IMAGES`、Android 12L/12 以下: `READ_EXTERNAL_STORAGE`/`WRITE_EXTERNAL_STORAGE`）
- 用途: 写真を選択・読み込み、EXIF メタデータを参照してファイル名を生成し、リネームした写真を端末に保存/エクスポートするために使用します。
- データの取り扱い: 写真データとメタデータの処理はすべて端末内で完結し、外部サーバーへ送信しません。バックグラウンドでのアクセスも行いません。
- ユーザーへの価値: 権限がない場合、写真の選択・リネーム・保存といった主機能が利用できません。

Play Console（権限の宣言）例:

- 「この権限はアプリの中核機能に必要です」を選択
- 具体的な使用方法: 「ユーザーが端末内の写真を選択し、EXIF 情報を読み取って新しいファイル名を生成し、端末に保存（エクスポート）するため。」
- データ送信: 「送信しない」
- バックグラウンドアクセス: 「行わない」

アプリ内ダイアログ（権限リクエスト前）例:

- タイトル: 写真へのアクセス許可が必要です
- 本文: PhotoRename は、写真を選択して EXIF 情報を読み取り、ファイル名を変更・保存するために「写真と動画」へのアクセス権限が必要です。処理は端末内でのみ行われ、データは外部に送信されません。
- 拒否時の案内: 権限がないため写真を読み込めません。端末の設定から PhotoRename の権限を許可してください。
