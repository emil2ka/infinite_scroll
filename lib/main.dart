import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
// 0. ТОЧКА ВХОДА
// ============================================================================
// Теперь main() асинхронная: перед запуском UI мы синхронно поднимаем
// SharedPreferences (наше локальное хранилище/кеш), чтобы провайдеры могли
// сразу прочитать сохранённые сессию, избранное и корзину.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MyApp(prefs: prefs));
}

// Базовый адрес API. Все запросы идут сюда (DummyJSON — тестовый REST API,
// у него есть готовые эндпоинты авторизации /auth/login, /auth/me, /auth/refresh).
const String kBaseUrl = 'https://dummyjson.com';

// ============================================================================
// 1. МОДЕЛИ ДАННЫХ
// ============================================================================

/// Товар каталога. Добавили описание и рейтинг (нужны для карточки товара
/// в стиле маркетплейса) и toJson() — чтобы уметь класть товар в кеш.
class Product {
  final int id;
  final String title;
  final double price;
  final String thumbnail;
  final String? description;
  final double? rating;

  Product({
    required this.id,
    required this.title,
    required this.price,
    required this.thumbnail,
    this.description,
    this.rating,
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['id'] as int,
      title: json['title'] as String,
      price: (json['price'] as num).toDouble(),
      thumbnail: json['thumbnail'] as String,
      description: json['description'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
    );
  }

  /// Обратная сериализация — превращаем товар в Map, чтобы сохранить в кеш.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'price': price,
        'thumbnail': thumbnail,
        'description': description,
        'rating': rating,
      };
}

/// Пользователь. Приходит и от DummyJSON (/auth/login, /auth/me), и хранится
/// в кеше для локальных аккаунтов.
class User {
  final int id;
  final String username;
  final String email;
  final String firstName;
  final String lastName;
  final String? image;

  User({
    required this.id,
    required this.username,
    required this.email,
    required this.firstName,
    required this.lastName,
    this.image,
  });

  String get fullName => '$firstName $lastName'.trim();

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username'] as String? ?? '',
      email: json['email'] as String? ?? '',
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
      image: json['image'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'email': email,
        'firstName': firstName,
        'lastName': lastName,
        'image': image,
      };
}

/// Ответ эндпоинта /auth/login: два токена + данные пользователя.
class AuthResponse {
  final String accessToken;
  final String refreshToken;
  final User user;

  AuthResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    return AuthResponse(
      accessToken: json['accessToken'] as String? ?? '',
      refreshToken: json['refreshToken'] as String? ?? '',
      // Тот же JSON-объект содержит поля пользователя (id, username, email...).
      user: User.fromJson(json),
    );
  }
}

/// Позиция корзины: товар + количество. Геттер total считает сумму по позиции.
class CartItem {
  final Product product;
  int quantity;

  CartItem({required this.product, this.quantity = 1});

  double get total => product.price * quantity;

  factory CartItem.fromJson(Map<String, dynamic> json) => CartItem(
        product: Product.fromJson(json['product'] as Map<String, dynamic>),
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'quantity': quantity,
      };
}

// ============================================================================
// 2. JWT-УТИЛИТЫ
// ============================================================================
/// JWT — это три части, разделённые точками: header.payload.signature.
/// В payload (вторая часть) лежит поле exp — время истечения в Unix-секундах.
/// Мы декодируем его из base64url прямо в приложении, чтобы понимать,
/// истёк ли accessToken и пора ли его обновлять.
class JwtUtils {
  /// Возвращает время истечения токена (Unix-секунды) или null, если токен
  /// не похож на JWT (например, синтетический токен локального аккаунта).
  static int? expiry(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;

      // base64url может быть без padding — добиваем '=' до длины, кратной 4.
      String payload = parts[1];
      final pad = payload.length % 4;
      if (pad != 0) payload = payload.padRight(payload.length + (4 - pad), '=');

      final decoded = utf8.decode(base64Url.decode(payload));
      final Map<String, dynamic> json = jsonDecode(decoded);
      return (json['exp'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// Истёк ли токен. Если exp определить нельзя (не JWT) — считаем, что НЕ истёк,
  /// чтобы не выкидывать локального пользователя на экран логина.
  /// Небольшой запас (30 сек) — чтобы не отправить запрос с токеном, который
  /// истечёт прямо во время выполнения.
  static bool isExpired(String token) {
    final exp = expiry(token);
    if (exp == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    return exp - 30 < now;
  }
}

// ============================================================================
// 3. CACHE SERVICE (обёртка над SharedPreferences)
// ============================================================================
/// Прячет работу с SharedPreferences за удобными методами. SharedPreferences
/// хранит простые пары ключ-значение, поэтому списки/объекты кладём как
/// JSON-строки. Чтение синхронное, запись — асинхронная (но await можно не ждать).
class CacheService {
  final SharedPreferences prefs;
  CacheService(this.prefs);

  // --- Ключи хранилища ---
  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kUsername = 'session_username';
  static const _kIsLocal = 'session_is_local';
  static const _kUser = 'session_user';
  static const _kAccounts = 'local_accounts';
  static const _kProducts = 'cached_products';
  static const _kFavorites = 'favorites';
  static const _kCart = 'cart';

  // --- Сессия / токены ---
  Future<void> saveSession({
    required String access,
    required String refresh,
    required bool isLocal,
    required User user,
  }) async {
    await prefs.setString(_kAccess, access);
    await prefs.setString(_kRefresh, refresh);
    await prefs.setBool(_kIsLocal, isLocal);
    await prefs.setString(_kUsername, user.username);
    await prefs.setString(_kUser, jsonEncode(user.toJson()));
  }

  Future<void> saveTokens({required String access, required String refresh}) async {
    await prefs.setString(_kAccess, access);
    await prefs.setString(_kRefresh, refresh);
  }

  String? readAccess() => prefs.getString(_kAccess);
  String? readRefresh() => prefs.getString(_kRefresh);
  String? readUsername() => prefs.getString(_kUsername);
  bool readIsLocal() => prefs.getBool(_kIsLocal) ?? false;

  User? readUser() {
    final raw = prefs.getString(_kUser);
    if (raw == null) return null;
    try {
      return User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearSession() async {
    await prefs.remove(_kAccess);
    await prefs.remove(_kRefresh);
    await prefs.remove(_kUser);
    await prefs.remove(_kUsername);
    await prefs.remove(_kIsLocal);
  }

  // --- Локальные аккаунты (регистрация) ---
  // Храним как Map: { "username": { "password": "...", "email": "..." } }.
  // ВНИМАНИЕ: пароль лежит в открытом виде — это ок для учебного проекта,
  // но в реальном приложении пароль нужно хешировать (bcrypt/sha256).
  Map<String, dynamic> _accounts() {
    final raw = prefs.getString(_kAccounts);
    if (raw == null) return {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  bool usernameExists(String username) =>
      _accounts().containsKey(username.toLowerCase());

  Future<void> saveLocalAccount({
    required String username,
    required String password,
    required String email,
  }) async {
    final accounts = _accounts();
    accounts[username.toLowerCase()] = {'password': password, 'email': email};
    await prefs.setString(_kAccounts, jsonEncode(accounts));
  }

  /// Возвращает запись аккаунта, если логин+пароль совпали, иначе null.
  Map<String, dynamic>? findLocalAccount(String username, String password) {
    final entry = _accounts()[username.toLowerCase()];
    if (entry is Map && entry['password'] == password) {
      return Map<String, dynamic>.from(entry);
    }
    return null;
  }

  // --- Кеш каталога товаров ---
  Future<void> saveProducts(List<Product> products) async {
    await prefs.setString(
      _kProducts,
      jsonEncode(products.map((p) => p.toJson()).toList()),
    );
  }

  List<Product> readProducts() {
    final raw = prefs.getString(_kProducts);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Product.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // --- Избранное ---
  Future<void> saveFavorites(Set<int> favorites) async {
    await prefs.setString(_kFavorites, jsonEncode(favorites.toList()));
  }

  Set<int> readFavorites() {
    final raw = prefs.getString(_kFavorites);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as List).map((e) => e as int).toSet();
    } catch (_) {
      return {};
    }
  }

  // --- Корзина ---
  Future<void> saveCart(List<CartItem> cart) async {
    await prefs.setString(
      _kCart,
      jsonEncode(cart.map((e) => e.toJson()).toList()),
    );
  }

  List<CartItem> readCart() {
    final raw = prefs.getString(_kCart);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => CartItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

// ============================================================================
// 4. API CLIENT (http + автоматическая подстановка Bearer-токена)
// ============================================================================
/// Единая точка для сетевых запросов. Сама добавляет заголовок
/// `Authorization: Bearer <accessToken>`. Если сервер отвечает 401 (токен истёк),
/// просит AuthProvider обновить токен и повторяет запрос ровно один раз.
class ApiClient {
  final CacheService cache;
  ApiClient(this.cache);

  /// Колбэк обновления токена. Его выставляет AuthService, чтобы не было
  /// циклической зависимости ApiClient <-> AuthProvider.
  Future<bool> Function()? onUnauthorized;

  Map<String, String> _headers({required bool withAuth}) {
    final headers = {'Content-Type': 'application/json'};
    final token = cache.readAccess();
    // Локальным аккаунтам синтетический токен в DummyJSON слать нельзя —
    // он не JWT и вызовет 401. Поэтому Bearer подставляем только для
    // реальных (DummyJSON) сессий.
    if (withAuth && !cache.readIsLocal() && token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<http.Response> get(
    String path, {
    Map<String, String>? query,
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$kBaseUrl$path').replace(queryParameters: query);
    var res = await http.get(uri, headers: _headers(withAuth: withAuth));

    if (res.statusCode == 401 && withAuth && onUnauthorized != null) {
      if (await onUnauthorized!()) {
        res = await http.get(uri, headers: _headers(withAuth: withAuth));
      }
    }
    return res;
  }

  Future<http.Response> post(
    String path,
    Map<String, dynamic> body, {
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$kBaseUrl$path');
    var res = await http.post(
      uri,
      headers: _headers(withAuth: withAuth),
      body: jsonEncode(body),
    );

    if (res.statusCode == 401 && withAuth && onUnauthorized != null) {
      if (await onUnauthorized!()) {
        res = await http.post(
          uri,
          headers: _headers(withAuth: withAuth),
          body: jsonEncode(body),
        );
      }
    }
    return res;
  }
}

// ============================================================================
// 5. AUTH SERVICE (логика авторизации)
// ============================================================================
/// Ошибка авторизации с человекочитаемым текстом (показываем в UI).
class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class AuthService {
  final ApiClient api;
  final CacheService cache;

  AuthService(this.api, this.cache) {
    // Подключаем авто-refresh: ApiClient вызовет этот метод при 401.
    api.onUnauthorized = refreshTokens;
  }

  /// Вход. Сначала ищем локальный аккаунт (созданный через регистрацию),
  /// и только потом идём в DummyJSON (тестовые юзеры вроде emilys/emilyspass).
  Future<AuthResponse> login(String username, String password) async {
    final local = cache.findLocalAccount(username, password);
    if (local != null) {
      // Для локального аккаунта токен синтетический (без точек => не JWT).
      final user = User(
        id: username.toLowerCase().hashCode.abs() % 100000,
        username: username,
        email: local['email'] as String? ?? '$username@local',
        firstName: username,
        lastName: '(локальный)',
      );
      final access = 'local-token-$username';
      await cache.saveSession(
        access: access,
        refresh: '',
        isLocal: true,
        user: user,
      );
      return AuthResponse(accessToken: access, refreshToken: '', user: user);
    }

    final res = await api.post(
      '/auth/login',
      {'username': username, 'password': password, 'expiresInMins': 30},
      withAuth: false,
    );

    if (res.statusCode == 200) {
      final auth = AuthResponse.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>,
      );
      await cache.saveSession(
        access: auth.accessToken,
        refresh: auth.refreshToken,
        isLocal: false,
        user: auth.user,
      );
      return auth;
    }

    // DummyJSON при ошибке возвращает {"message": "Invalid credentials"}.
    String message = 'Неверный логин или пароль';
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['message'] is String) message = data['message'] as String;
    } catch (_) {}
    throw AuthException(message);
  }

  /// Регистрация. DummyJSON новых пользователей НЕ сохраняет, поэтому
  /// аккаунт создаём локально в SharedPreferences, а затем сразу логиним.
  Future<AuthResponse> register({
    required String username,
    required String password,
    required String email,
  }) async {
    if (cache.usernameExists(username)) {
      throw AuthException('Пользователь уже существует');
    }
    await cache.saveLocalAccount(
      username: username,
      password: password,
      email: email,
    );
    return login(username, password);
  }

  /// Обновление accessToken по refreshToken. Возвращает true при успехе.
  /// Используется и при авто-входе, и как колбэк ApiClient при 401.
  Future<bool> refreshTokens() async {
    final refresh = cache.readRefresh();
    if (refresh == null || refresh.isEmpty) return false;
    try {
      final res = await api.post(
        '/auth/refresh',
        {'refreshToken': refresh, 'expiresInMins': 30},
        withAuth: false,
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final newAccess = data['accessToken'] as String?;
        if (newAccess == null) return false;
        await cache.saveTokens(
          access: newAccess,
          refresh: data['refreshToken'] as String? ?? refresh,
        );
        return true;
      }
    } catch (e) {
      debugPrint('Ошибка обновления токена: $e');
    }
    return false;
  }

  /// Профиль текущего пользователя (GET /auth/me с Bearer-токеном).
  Future<User?> fetchMe() async {
    try {
      final res = await api.get('/auth/me');
      if (res.statusCode == 200) {
        return User.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('Ошибка загрузки профиля: $e');
    }
    return null;
  }
}

// ============================================================================
// 6. AUTH PROVIDER (состояние авторизации)
// ============================================================================
enum AuthStatus { unknown, loggedOut, loggedIn }

class AuthProvider extends ChangeNotifier {
  final AuthService service;
  AuthProvider(this.service);

  AuthStatus _status = AuthStatus.unknown;
  User? _user;
  String? _error;
  bool _busy = false;

  AuthStatus get status => _status;
  User? get user => _user;
  String? get error => _error;
  bool get busy => _busy;

  /// Автовход при старте приложения:
  /// 1) нет сохранённого accessToken -> разлогинен;
  /// 2) токен истёк, но есть refreshToken -> обновляем; не вышло -> разлогинен;
  /// 3) токен живой -> восстанавливаем профиль (из сети или из кеша).
  Future<void> tryAutoLogin() async {
    final access = service.cache.readAccess();
    if (access == null || access.isEmpty) {
      _status = AuthStatus.loggedOut;
      notifyListeners();
      return;
    }

    if (JwtUtils.isExpired(access)) {
      final ok = await service.refreshTokens();
      if (!ok) {
        await service.cache.clearSession();
        _status = AuthStatus.loggedOut;
        notifyListeners();
        return;
      }
    }

    if (service.cache.readIsLocal()) {
      // Локальный аккаунт: профиль берём из кеша, в сеть не ходим.
      _user = service.cache.readUser();
    } else {
      // DummyJSON: свежий профиль из /auth/me, при сбое — из кеша.
      _user = await service.fetchMe() ?? service.cache.readUser();
    }
    _status = _user != null ? AuthStatus.loggedIn : AuthStatus.loggedOut;
    notifyListeners();
  }

  Future<bool> login(String username, String password) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final auth = await service.login(username, password);
      _user = auth.user;
      _status = AuthStatus.loggedIn;
      return true;
    } on AuthException catch (e) {
      _error = e.message;
      return false;
    } catch (e) {
      _error = 'Ошибка сети: $e';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> register({
    required String username,
    required String password,
    required String email,
  }) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final auth = await service.register(
        username: username,
        password: password,
        email: email,
      );
      _user = auth.user;
      _status = AuthStatus.loggedIn;
      return true;
    } on AuthException catch (e) {
      _error = e.message;
      return false;
    } catch (e) {
      _error = 'Ошибка регистрации: $e';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await service.cache.clearSession();
    _user = null;
    _status = AuthStatus.loggedOut;
    _error = null;
    notifyListeners();
  }
}

// ============================================================================
// 7. PRODUCT PROVIDER (каталог, поиск, избранное, корзина)
// ============================================================================
class ProductProvider extends ChangeNotifier {
  final CacheService cache;
  final ApiClient api;

  ProductProvider({required this.cache, required this.api}) {
    // Избранное и корзину поднимаем из кеша сразу при создании провайдера.
    _favorites = cache.readFavorites();
    _cart = cache.readCart();
  }

  // --- Каталог ---
  final List<Product> _products = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  int _skip = 0;
  final int _limit = 10;
  bool _hasMore = true;

  // --- Поиск ---
  String _query = '';
  List<Product> _searchResults = [];
  bool _isSearching = false;
  Timer? _debounce;

  // --- Избранное ---
  late Set<int> _favorites;

  // --- Корзина ---
  late List<CartItem> _cart;

  // Геттеры
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;
  bool get isSearching => _isSearching;
  bool get isSearchMode => _query.trim().isNotEmpty;
  Set<int> get favorites => _favorites;
  List<CartItem> get cart => _cart;
  int get favoritesCount => _favorites.length;
  int get cartCount => _cart.fold(0, (sum, item) => sum + item.quantity);
  double get cartTotal => _cart.fold(0.0, (sum, item) => sum + item.total);

  /// Текущий список для отображения: результаты поиска или обычный каталог.
  List<Product> get visibleProducts =>
      isSearchMode ? _searchResults : _products;

  /// Список товаров, добавленных в избранное (для вкладки «Избранное»).
  List<Product> get favoriteProducts =>
      _products.where((p) => _favorites.contains(p.id)).toList();

  bool isFavorite(int id) => _favorites.contains(id);

  // ----------------------------------------------------
  // Каталог: первичная загрузка (сначала кеш, затем сеть)
  // ----------------------------------------------------
  Future<void> fetchInitialProducts() async {
    _isLoading = true;
    _skip = 0;
    _hasMore = true;
    notifyListeners();

    // Офлайн-first: если кеш есть, показываем его мгновенно, ещё до сети.
    final cached = cache.readProducts();
    if (_products.isEmpty && cached.isNotEmpty) {
      _products.addAll(cached);
      notifyListeners();
    }

    try {
      final res = await api.get('/products', query: {
        'limit': '$_limit',
        'skip': '0',
      });

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final loaded = (data['products'] as List)
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList();

        _products
          ..clear()
          ..addAll(loaded);
        _skip = loaded.length;
        _hasMore = loaded.length == _limit;

        await cache.saveProducts(_products);
      }
    } catch (e) {
      // Сеть недоступна — остаёмся на данных из кеша (если он был).
      debugPrint('Ошибка при первичной загрузке: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ----------------------------------------------------
  // Каталог: бесконечная прокрутка (подгрузка следующей порции)
  // ----------------------------------------------------
  Future<void> fetchMoreProducts() async {
    // В режиме поиска пагинация не нужна — сервер вернул все совпадения.
    if (_isLoadingMore || _isLoading || !_hasMore || isSearchMode) return;

    _isLoadingMore = true;
    notifyListeners();

    try {
      final res = await api.get('/products', query: {
        'limit': '$_limit',
        'skip': '$_skip',
      });

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final newProducts = (data['products'] as List)
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList();

        _products.addAll(newProducts);
        _skip += newProducts.length;
        if (newProducts.length < _limit) _hasMore = false;

        await cache.saveProducts(_products);
      }
    } catch (e) {
      debugPrint('Ошибка при подгрузке: $e');
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  // ----------------------------------------------------
  // Поиск с debounce (ждём 400мс после последнего символа)
  // ----------------------------------------------------
  void onSearchChanged(String query) {
    _query = query;
    _debounce?.cancel();

    if (query.trim().isEmpty) {
      _searchResults = [];
      _isSearching = false;
      notifyListeners();
      return;
    }

    _isSearching = true;
    notifyListeners();
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _runSearch(query),
    );
  }

  Future<void> _runSearch(String query) async {
    try {
      final res = await api.get('/products/search', query: {'q': query});
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (data['products'] as List)
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList();
        // Показываем результат, только если пользователь не начал печатать другое.
        if (_query == query) _searchResults = list;
      }
    } catch (e) {
      debugPrint('Ошибка поиска: $e');
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  // ----------------------------------------------------
  // Избранное
  // ----------------------------------------------------
  Future<void> toggleFavorite(int id) async {
    if (_favorites.contains(id)) {
      _favorites.remove(id);
    } else {
      _favorites.add(id);
    }
    notifyListeners();
    await cache.saveFavorites(_favorites);
  }

  // ----------------------------------------------------
  // Корзина (в стиле маркетплейса)
  // ----------------------------------------------------
  Future<void> addToCart(Product product) async {
    final existing = _cart.where((i) => i.product.id == product.id).firstOrNull;
    if (existing != null) {
      existing.quantity++;
    } else {
      _cart.add(CartItem(product: product));
    }
    notifyListeners();
    await cache.saveCart(_cart);
  }

  Future<void> increment(int productId) async {
    final item = _cart.where((i) => i.product.id == productId).firstOrNull;
    if (item != null) {
      item.quantity++;
      notifyListeners();
      await cache.saveCart(_cart);
    }
  }

  /// Уменьшаем количество; на нуле — удаляем позицию.
  Future<void> decrement(int productId) async {
    final item = _cart.where((i) => i.product.id == productId).firstOrNull;
    if (item == null) return;
    if (item.quantity <= 1) {
      _cart.remove(item);
    } else {
      item.quantity--;
    }
    notifyListeners();
    await cache.saveCart(_cart);
  }

  Future<void> removeFromCart(int productId) async {
    _cart.removeWhere((i) => i.product.id == productId);
    notifyListeners();
    await cache.saveCart(_cart);
  }

  /// Имитация оформления заказа — очищаем корзину.
  Future<void> checkout() async {
    _cart.clear();
    notifyListeners();
    await cache.saveCart(_cart);
  }

  @override
  void dispose() {
    // Отменяем отложенный поиск, чтобы не дёрнуть notifyListeners после dispose.
    _debounce?.cancel();
    super.dispose();
  }
}

// ============================================================================
// 8. КОРНЕВОЙ ВИДЖЕТ И ВНЕДРЕНИЕ ЗАВИСИМОСТЕЙ
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

// ============================================================================
// 9. ЭКРАН ВХОДА
// ============================================================================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    final ok = await auth.login(_username.text.trim(), _password.text);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(auth.error ?? 'Не удалось войти')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.shopping_bag,
                      size: 64, color: Colors.deepOrange),
                  const SizedBox(height: 12),
                  Text(
                    'Маркетплейс',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Войдите, чтобы продолжить',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(
                      labelText: 'Логин',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Введите логин' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Пароль',
                      prefixIcon: Icon(Icons.lock_outline),
                      border: OutlineInputBorder(),
                    ),
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Введите пароль' : null,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: auth.busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: auth.busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Войти'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: auth.busy
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const RegisterScreen(),
                              ),
                            ),
                    child: const Text('Нет аккаунта? Зарегистрироваться'),
                  ),
                  const Divider(height: 32),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.deepOrange.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Тестовый вход через DummyJSON:\n'
                      'логин emilys / пароль emilyspass',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 10. ЭКРАН РЕГИСТРАЦИИ
// ============================================================================
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    final ok = await auth.register(
      username: _username.text.trim(),
      password: _password.text,
      email: _email.text.trim(),
    );
    if (ok && mounted) {
      // Аккаунт создан и сразу выполнен вход — закрываем экран регистрации,
      // AuthGate сам переключится на основной экран.
      // Сообщение показываем через messenger, полученный ДО pop():
      // после pop() контекст этого экрана становится недействительным.
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Аккаунт создан, вы вошли')),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(auth.error ?? 'Не удалось зарегистрироваться')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Регистрация')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: 'Логин',
                    prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.trim().length < 3)
                      ? 'Минимум 3 символа'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.email_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || !v.contains('@'))
                      ? 'Некорректный email'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Пароль',
                    prefixIcon: Icon(Icons.lock_outline),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.length < 6) ? 'Минимум 6 символов' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _confirm,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Повторите пароль',
                    prefixIcon: Icon(Icons.lock_outline),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      v != _password.text ? 'Пароли не совпадают' : null,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: auth.busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: auth.busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Зарегистрироваться'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Аккаунт сохраняется локально на устройстве '
                  '(DummyJSON не хранит новых пользователей).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 11. ГЛАВНЫЙ ЭКРАН С НИЖНЕЙ НАВИГАЦИЕЙ (Каталог / Избранное / Корзина / Профиль)
// ============================================================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const _titles = ['Каталог', 'Избранное', 'Корзина', 'Профиль'];

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ProductProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        centerTitle: true,
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          CatalogTab(),
          FavoritesTab(),
          CartTab(),
          ProfileTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Каталог',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: provider.favoritesCount > 0,
              label: Text('${provider.favoritesCount}'),
              child: const Icon(Icons.favorite_border),
            ),
            selectedIcon: Badge(
              isLabelVisible: provider.favoritesCount > 0,
              label: Text('${provider.favoritesCount}'),
              child: const Icon(Icons.favorite),
            ),
            label: 'Избранное',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: provider.cartCount > 0,
              label: Text('${provider.cartCount}'),
              child: const Icon(Icons.shopping_cart_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: provider.cartCount > 0,
              label: Text('${provider.cartCount}'),
              child: const Icon(Icons.shopping_cart),
            ),
            label: 'Корзина',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Профиль',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 12. ВКЛАДКА «КАТАЛОГ» (поиск + бесконечный скролл)
// ============================================================================
class CatalogTab extends StatefulWidget {
  const CatalogTab({super.key});

  @override
  State<CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends State<CatalogTab> {
  final _scrollController = ScrollController();
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);

    // Первичную загрузку запускаем один раз после первого кадра.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_started) return;
      _started = true;
      context.read<ProductProvider>().fetchInitialProducts();
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      context.read<ProductProvider>().fetchMoreProducts();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ProductProvider>();
    final products = provider.visibleProducts;

    return Column(
      children: [
        // Строка поиска с debounce (логика — в ProductProvider.onSearchChanged).
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            onChanged: provider.onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Поиск товаров...',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: provider.isLoading && products.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: () => provider.fetchInitialProducts(),
                  child: ListView.builder(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    // +1 — футер (индикатор подгрузки / конец списка / "ничего не найдено").
                    itemCount: products.length + 1,
                    itemBuilder: (context, index) {
                      if (index == products.length) {
                        return _buildFooter(context, provider, products.length);
                      }
                      final product = products[index];
                      return ProductCard(product: product);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildFooter(
    BuildContext context,
    ProductProvider provider,
    int itemCount,
  ) {
    if (provider.isSearching) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (itemCount == 0) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('Ничего не найдено 🔍')),
      );
    }
    if (provider.isSearchMode) {
      // В режиме поиска фиксированного конца нет — показываем счётчик.
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text('Результаты поиска', style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    if (provider.hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          'Больше товаров нет 🎉',
          style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

// ============================================================================
// 13. КАРТОЧКА ТОВАРА (переиспользуется в каталоге и избранном)
// ============================================================================
class ProductCard extends StatelessWidget {
  final Product product;
  const ProductCard({super.key, required this.product});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ProductProvider>();
    final isFav = provider.isFavorite(product.id);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showModalBottomSheet(
          context: context,
          showDragHandle: true,
          builder: (_) => ProductDetailSheet(product: product),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  product.thumbnail,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    width: 64,
                    height: 64,
                    color: Colors.grey[200],
                    child: const Icon(Icons.image_not_supported,
                        color: Colors.grey),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '\$${product.price.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
              // Сердечко — избранное.
              IconButton(
                onPressed: () => provider.toggleFavorite(product.id),
                icon: Icon(
                  isFav ? Icons.favorite : Icons.favorite_border,
                  color: isFav ? Colors.redAccent : Colors.grey,
                ),
                tooltip: 'В избранное',
              ),
              // Кнопка добавления в корзину.
              IconButton.filledTonal(
                onPressed: () {
                  provider.addToCart(product);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('«${product.title}» в корзине'),
                      duration: const Duration(milliseconds: 900),
                    ),
                  );
                },
                icon: const Icon(Icons.add_shopping_cart),
                tooltip: 'В корзину',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 14. ДЕТАЛЬНЫЙ ПРОСМОТР ТОВАРА (bottom sheet)
// ============================================================================
class ProductDetailSheet extends StatelessWidget {
  final Product product;
  const ProductDetailSheet({super.key, required this.product});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ProductProvider>();
    final isFav = provider.isFavorite(product.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                product.thumbnail,
                height: 200,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const SizedBox(
                  height: 200,
                  child: Icon(Icons.image_not_supported,
                      size: 64, color: Colors.grey),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            product.title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '\$${product.price.toStringAsFixed(2)}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                ),
              ),
              const SizedBox(width: 12),
              if (product.rating != null)
                Row(
                  children: [
                    const Icon(Icons.star, color: Colors.amber, size: 18),
                    Text(' ${product.rating!.toStringAsFixed(1)}'),
                  ],
                ),
            ],
          ),
          if (product.description != null) ...[
            const SizedBox(height: 12),
            Text(
              product.description!,
              style: const TextStyle(color: Colors.black87, height: 1.4),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              IconButton.outlined(
                onPressed: () => provider.toggleFavorite(product.id),
                icon: Icon(
                  isFav ? Icons.favorite : Icons.favorite_border,
                  color: isFav ? Colors.redAccent : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    provider.addToCart(product);
                    // messenger берём до pop(), чтобы контекст не оказался мёртвым.
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.of(context).pop();
                    messenger.showSnackBar(
                      SnackBar(content: Text('«${product.title}» в корзине')),
                    );
                  },
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text('Добавить в корзину'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 15. ВКЛАДКА «ИЗБРАННОЕ»
// ============================================================================
class FavoritesTab extends StatelessWidget {
  const FavoritesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ProductProvider>();
    final favorites = provider.favoriteProducts;

    if (favorites.isEmpty) {
      return const _EmptyState(
        icon: Icons.favorite_border,
        text: 'В избранном пока пусто.\nНажмите ♥ на товаре, чтобы добавить.',
      );
    }

    return ListView.builder(
      itemCount: favorites.length,
      itemBuilder: (context, index) => ProductCard(product: favorites[index]),
    );
  }
}

// ============================================================================
// 16. ВКЛАДКА «КОРЗИНА»
// ============================================================================
class CartTab extends StatelessWidget {
  const CartTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ProductProvider>();
    final cart = provider.cart;

    if (cart.isEmpty) {
      return const _EmptyState(
        icon: Icons.shopping_cart_outlined,
        text: 'Корзина пуста.\nДобавьте товары из каталога.',
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: cart.length,
            itemBuilder: (context, index) => _CartRow(item: cart[index]),
          ),
        ),
        // Итог и оформление заказа.
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Итого', style: TextStyle(color: Colors.grey)),
                    Text(
                      '\$${provider.cartTotal.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => _checkout(context, provider),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Оформить заказ'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _checkout(BuildContext context, ProductProvider provider) async {
    final total = provider.cartTotal;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Оформление заказа'),
        content: Text(
          'Оформить заказ на сумму \$${total.toStringAsFixed(2)}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await provider.checkout();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 8),
            Text('Заказ оформлен'),
          ],
        ),
        content: Text('Спасибо за покупку на \$${total.toStringAsFixed(2)}!'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Отлично'),
          ),
        ],
      ),
    );
  }
}

class _CartRow extends StatelessWidget {
  final CartItem item;
  const _CartRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<ProductProvider>();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                item.product.thumbnail,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  width: 56,
                  height: 56,
                  color: Colors.grey[200],
                  child: const Icon(Icons.image, color: Colors.grey),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.product.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '\$${item.total.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            // Счётчик количества: - / +.
            IconButton(
              onPressed: () => provider.decrement(item.product.id),
              icon: const Icon(Icons.remove_circle_outline),
            ),
            Text('${item.quantity}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            IconButton(
              onPressed: () => provider.increment(item.product.id),
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 17. ВКЛАДКА «ПРОФИЛЬ»
// ============================================================================
class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 12),
        Center(
          child: CircleAvatar(
            radius: 48,
            backgroundColor: Colors.deepOrange.withValues(alpha: 0.15),
            backgroundImage:
                (user?.image != null) ? NetworkImage(user!.image!) : null,
            child: (user?.image == null)
                ? const Icon(Icons.person, size: 48, color: Colors.deepOrange)
                : null,
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            user?.fullName.isNotEmpty == true ? user!.fullName : '@${user?.username ?? ''}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            user?.email ?? '',
            style: const TextStyle(color: Colors.grey),
          ),
        ),
        const SizedBox(height: 28),
        Card(
          child: ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Логин'),
            trailing: Text(user?.username ?? '—'),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('ID пользователя'),
            trailing: Text('${user?.id ?? '—'}'),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () => context.read<AuthProvider>().logout(),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: const Icon(Icons.logout),
          label: const Text('Выйти'),
        ),
      ],
    );
  }
}

// ============================================================================
// 18. ВСПОМОГАТЕЛЬНЫЙ ВИДЖЕТ — ПУСТОЕ СОСТОЯНИЕ
// ============================================================================
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyState({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}
