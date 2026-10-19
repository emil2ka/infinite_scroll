// ============================================================================
// models.dart — МОДЕЛИ ДАННЫХ
// ============================================================================
// Этот файл ничего не знает ни про экраны, ни про сеть. Здесь только структуры
// данных (классы), которые используются во всём приложении:
//
//   Product      — товар каталога DummyJSON;
//   User         — пользователь (из /auth/login, /auth/me или локальный);
//   AuthResponse — пара токенов + пользователь (ответ /auth/login);
//   CartItem     — строка корзины: товар + количество;
//   JwtUtils     — утилита для чтения срока действия JWT-токена.
//
// fromJson() превращает Map из JSON в объект Dart, а toJson() — обратно в Map.
// Второе нужно, чтобы сохранять объекты в кеш SharedPreferences.

import 'dart:convert';

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
// JWT-УТИЛИТЫ
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
