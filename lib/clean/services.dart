import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

const String kBaseUrl = 'https://dummyjson.com';

class CacheService {
  final SharedPreferences prefs;
  CacheService(this.prefs);

  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kUsername = 'session_username';
  static const _kIsLocal = 'session_is_local';
  static const _kUser = 'session_user';
  static const _kAccounts = 'local_accounts';
  static const _kProducts = 'cached_products';
  static const _kFavorites = 'favorites';
  static const _kCart = 'cart';

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

  Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
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

  Map<String, dynamic>? findLocalAccount(String username, String password) {
    final entry = _accounts()[username.toLowerCase()];
    if (entry is Map && entry['password'] == password) {
      return Map<String, dynamic>.from(entry);
    }
    return null;
  }

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

class ApiClient {
  final CacheService cache;
  ApiClient(this.cache);

  Future<bool> Function()? onUnauthorized;

  Map<String, String> _headers({required bool withAuth}) {
    final headers = {'Content-Type': 'application/json'};
    final token = cache.readAccess();
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
    api.onUnauthorized = refreshTokens;
  }

  Future<AuthResponse> login(String username, String password) async {
    final local = cache.findLocalAccount(username, password);
    if (local != null) {
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

    final res = await api.post('/auth/login', {
      'username': username,
      'password': password,
      'expiresInMins': 30,
    }, withAuth: false);

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

    String message = 'Неверный логин или пароль';
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['message'] is String) message = data['message'] as String;
    } catch (_) {}
    throw AuthException(message);
  }

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

  Future<bool> refreshTokens() async {
    final refresh = cache.readRefresh();
    if (refresh == null || refresh.isEmpty) return false;
    try {
      final res = await api.post('/auth/refresh', {
        'refreshToken': refresh,
        'expiresInMins': 30,
      }, withAuth: false);
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
