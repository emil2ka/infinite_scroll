// ============================================================================
// main.dart — ТОЧКА ВХОДА
// ============================================================================
// Порядок запуска:
//   1. main() поднимает SharedPreferences (локальный кеш);
//   2. MyApp собирает зависимости: CacheService -> ApiClient -> AuthService
//      и раздаёт провайдеры вниз по дереву виджетов через Provider;
//   3. AuthGate смотрит на AuthProvider.status и выбирает экран:
//        unknown  -> SplashScreen (идёт автовход),
//        loggedOut-> LoginScreen,
//        loggedIn -> HomeScreen.
//
// Файлы проекта:
//   models.dart    — данные (Product, User, CartItem, JwtUtils);
//   services.dart  — кеш, HTTP, авторизация;
//   providers.dart — состояние приложения (AuthProvider, ProductProvider);
//   screens.dart   — все экраны и виджеты.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers.dart';
import 'screens.dart';
import 'services.dart';

// ============================================================================
// ТОЧКА ВХОДА
// ============================================================================
// main() асинхронная: перед запуском UI мы поднимаем SharedPreferences
// (локальное хранилище/кеш), чтобы провайдеры могли сразу прочитать
// сохранённые сессию, избранное и корзину.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MyApp(prefs: prefs));
}

// ============================================================================
// КОРНЕВОЙ ВИДЖЕТ И ВНЕДРЕНИЕ ЗАВИСИМОСТЕЙ
// ============================================================================
class MyApp extends StatelessWidget {
  final SharedPreferences prefs;
  const MyApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    // Собираем зависимости вручную: кеш -> api -> сервис -> провайдеры.
    final cache = CacheService(prefs);
    final api = ApiClient(cache);
    final authService = AuthService(api, cache);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider(authService)),
        ChangeNotifierProvider(
          create: (_) => ProductProvider(cache: cache, api: api),
        ),
      ],
      child: MaterialApp(
        title: 'Маркетплейс на DummyJSON',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.deepOrange,
          useMaterial3: true,
        ),
        home: const AuthGate(),
      ),
    );
  }
}

/// Решает, что показать: сплэш, экран логина или основное приложение,
/// в зависимости от статуса авторизации.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    // Автовход запускаем после первого кадра, чтобы notifyListeners не
    // случился во время построения дерева виджетов.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().tryAutoLogin();
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = context.watch<AuthProvider>().status;
    switch (status) {
      case AuthStatus.unknown:
        return const SplashScreen();
      case AuthStatus.loggedOut:
        return const LoginScreen();
      case AuthStatus.loggedIn:
        return const HomeScreen();
    }
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.shopping_bag, size: 72, color: Colors.deepOrange),
            SizedBox(height: 16),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
