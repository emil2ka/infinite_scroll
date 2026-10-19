# infinite_scroll

A new Flutter project.

## Структура кода

Код разделён на два одинаковых по логике варианта — различаются только комментариями:

- `lib/clean/` — чистый код без комментариев;
- `lib/commented/` — тот же код с подробными объяснениями.

В каждой папке 5 файлов (4 модуля + точка входа):

| Файл | Что внутри |
| --- | --- |
| `main.dart` | точка входа, `MyApp`, `AuthGate`, сплэш |
| `models.dart` | `Product`, `User`, `CartItem`, `JwtUtils` |
| `services.dart` | `CacheService`, `ApiClient`, `AuthService` |
| `providers.dart` | `AuthProvider`, `ProductProvider` |
| `screens.dart` | все экраны и виджеты |

Запуск нужной версии:

```bash
flutter run -t lib/clean/main.dart
flutter run -t lib/commented/main.dart
```

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
