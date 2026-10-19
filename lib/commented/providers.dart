// ============================================================================
// providers.dart — СОСТОЯНИЕ ПРИЛОЖЕНИЯ (Provider / ChangeNotifier)
// ============================================================================
// Provider — это «хранилище состояния»: он держит данные, нужные нескольким
// виджетам, и сообщает им об изменениях через notifyListeners().
//
// Виджеты работают с провайдером так:
//   context.watch<T>() — подписаться и перерисовываться при изменениях;
//   context.read<T>()  — просто получить объект и вызвать его метод.
//
// Здесь два провайдера:
//   AuthProvider    — кто вошёл, статус авторизации, текст ошибки;
//   ProductProvider — каталог, поиск, избранное, корзина.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'services.dart';

// ============================================================================
// AUTH PROVIDER (состояние авторизации)
// ============================================================================
/// unknown — приложение ещё не знает, вошёл пользователь или нет (показываем
/// сплэш и пробуем автовход); loggedOut — экран логина; loggedIn — основное
/// приложение.
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
// PRODUCT PROVIDER (каталог, поиск, избранное, корзина)
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
      final res = await api.get(
        '/products',
        query: {'limit': '$_limit', 'skip': '0'},
      );

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
      final res = await api.get(
        '/products',
        query: {'limit': '$_limit', 'skip': '$_skip'},
      );

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
