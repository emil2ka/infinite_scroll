import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

/// Точка входа в приложение Flutter.
/// Функция main() запускает корневой виджет MyApp.
void main() {
  runApp(const MyApp());
}

// ============================================================================
// 1. МОДЕЛЬ ДАННЫХ (Data Model)
// ============================================================================
/// Класс Product представляет отдельный товар, полученный с сервера DummyJSON.
/// Он содержит только те поля, которые необходимы для отображения в списке.
class Product {
  final int id;            // Уникальный идентификатор товара
  final String title;     // Название товара
  final double price;     // Стоимость товара
  final String thumbnail; // Ссылка на превью-изображение

  Product({
    required this.id,
    required this.title,
    required this.price,
    required this.thumbnail,
  });

  /// Фабричный конструктор для парсинга (десериализации) данных из JSON (Map).
  /// Сервер возвращает цену как num (int или double), поэтому приводим к double:
  /// (json['price'] as num).toDouble() исключает падение при целых числах.
  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['id'] as int,
      title: json['title'] as String,
      price: (json['price'] as num).toDouble(),
      thumbnail: json['thumbnail'] as String,
    );
  }
}

// ============================================================================
// 2. ПРОВАЙДЕР ПАГИНАЦИИ (State Management с ChangeNotifier)
// ============================================================================
/// ProductProvider управляет состоянием списка товаров и пагинацией:
/// - Хранит загруженный список [_products]
/// - Следит за флагами загрузки [_isLoading] и [_isLoadingMore]
/// - Контролирует смещение пагинации [_skip] и лимит на страницу [_limit]
/// - Оповещает UI через notifyListeners() при каждом изменении состояния.
class ProductProvider with ChangeNotifier {
  // Список уже загруженных товаров
  final List<Product> _products = [];

  // Флаг первичной загрузки (показывает большой индикатор по центру экрана)
  bool _isLoading = false;

  // Флаг подгрузки следующей страницы (показывает индикатор внизу списка)
  bool _isLoadingMore = false;

  // Сколько элементов пропустить (для 1-й стр = 0, для 2-й = 10, для 3-й = 20...)
  int _skip = 0;

  // Количество элементов, запрашиваемых за один запрос к API
  final int _limit = 10;

  // Флаг наличия следующих данных: false означает, что мы дошли до конца каталога
  bool _hasMore = true;

  // Геттеры для безопасного чтения закрытых (private) полей из UI
  List<Product> get products => _products;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;

  // ----------------------------------------------------
  // МЕТОД 1: Первичная загрузка / Обновление (Pull-to-Refresh)
  // ----------------------------------------------------
  /// Вызывается при старте приложения или свайпе вниз (Pull-to-Refresh).
  /// Сбрасывает состояние к начальному и загружает первые 10 элементов.
  Future<void> fetchInitialProducts() async {
    // 1. Устанавливаем флаг первичной загрузки в true
    _isLoading = true;
    // 2. Сбрасываем счетчик пропущенных элементов на начало
    _skip = 0;
    // 3. Снова разрешаем подгрузку данных
    _hasMore = true;
    // 4. Очищаем старый список перед загрузкой новых данных
    _products.clear();
    // 5. Уведомляем слушателей (UI перерисовывается и показывает спиннер)
    notifyListeners();

    try {
      // Формируем URL с query-параметрами limit и skip
      final uri = Uri.parse('https://dummyjson.com/products?limit=$_limit&skip=$_skip');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        // Декодируем тело ответа из JSON строки в Dart Map
        final Map<String, dynamic> data = json.decode(response.body);
        final List<dynamic> productsJson = data['products'];

        // Превращаем каждый Map в типизированный объект Product
        final List<Product> loadedProducts = productsJson
            .map((item) => Product.fromJson(item as Map<String, dynamic>))
            .toList();

        // Добавляем полученные товары в наш список
        _products.addAll(loadedProducts);

        // Увеличиваем сдвиг skip на величину limit (следующий запрос начнётся с 10)
        _skip += _limit;

        // Если с сервера вернулось меньше товаров, чем limit, значит мы в конце
        if (loadedProducts.length < _limit) {
          _hasMore = false;
        }
      } else {
        debugPrint('Ошибка сервера: статус-код ${response.statusCode}');
      }
    } catch (error) {
      // Ловим ошибки сети (нет интернета, таймаут и т.д.)
      debugPrint('Ошибка при первичной загрузке: $error');
    } finally {
      // В любом случае (успех или ошибка) выключаем спиннер
      _isLoading = false;
      // Уведомляем UI о завершении загрузки
      notifyListeners();
    }
  }

  // ----------------------------------------------------
  // МЕТОД 2: Подгрузка следующей порции (Infinite Scroll)
  // ----------------------------------------------------
  /// Вызывается при приближении пользователя к концу списка.
  /// Добавляет новые элементы к уже существующим.
  Future<void> fetchMoreProducts() async {
    // ЗАЩИТА ОТ ДУБЛИРУЮЩИХСЯ ЗАПРОСОВ:
    // - Если прямо сейчас уже идёт подгрузка (_isLoadingMore)
    // - Или если идёт полная загрузка (_isLoading)
    // - Или данных на сервере больше нет (!_hasMore)
    // То мгновенно выходим из метода!
    if (_isLoadingMore || _isLoading || !_hasMore) return;

    // Включаем индикатор дозагрузки внизу списка
    _isLoadingMore = true;
    notifyListeners();

    try {
      final uri = Uri.parse('https://dummyjson.com/products?limit=$_limit&skip=$_skip');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final List<dynamic> productsJson = data['products'];

        final List<Product> newProducts = productsJson
            .map((item) => Product.fromJson(item as Map<String, dynamic>))
            .toList();

        // Добавляем порцию новых товаров в КОНЕЦ существующего списка
        _products.addAll(newProducts);

        // Увеличиваем сдвиг skip для следующего запроса
        _skip += _limit;

        // Если пришло меньше элементов чем limit — сервер исчерпал товары
        if (newProducts.length < _limit) {
          _hasMore = false;
        }
      }
    } catch (error) {
      debugPrint('Ошибка при подгрузке следующей страницы: $error');
    } finally {
      // Отключаем нижний индикатор и уведомляем UI
      _isLoadingMore = false;
      notifyListeners();
    }
  }
}

// ============================================================================
// 3. ГЛАВНЫЙ ВИДЖЕТ ПРИЛОЖЕНИЯ
// ============================================================================
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Внедряем ProductProvider в дерево виджетов через ChangeNotifierProvider.
    // Конструкция cascade (..) сразу запускает первичную загрузку данных.
    return ChangeNotifierProvider(
      create: (_) => ProductProvider()..fetchInitialProducts(),
      child: MaterialApp(
        title: 'Бесконечная лента и пагинация',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.deepOrange,
          useMaterial3: true,
        ),
        home: const ProductsScreen(),
      ),
    );
  }
}

// ============================================================================
// 4. ЭКРАН СПИСКА С ОТСЛЕЖИВАНИЕМ СКРОЛЛА (ScrollController)
// ============================================================================
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  // Контроллер скролла для отслеживания текущей позиции прокрутки
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    // Навешиваем слушатель (listener) на прокрутку списка.
    // Он срабатывает при каждом движении пальца пользователя по экрану.
    _scrollController.addListener(_onScroll);
  }

  /// Обработчик скролла:
  /// Проверяет, доскроллил ли пользователь до порогового значения (за 200px до конца).
  void _onScroll() {
    // _scrollController.position.pixels — текущее смещение скролла сверху
    // _scrollController.position.maxScrollExtent — максимальная доступная длина скролла
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      // context.read<T>() используется внутри колбэков, так как здесь
      // не требуется подписываться на перерисовку виджета
      context.read<ProductProvider>().fetchMoreProducts();
    }
  }

  @override
  void dispose() {
    // ОБЯЗАТЕЛЬНО: удаляем слушатель и освобождаем ScrollController,
    // чтобы предотвратить утечки памяти (memory leaks).
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // context.watch<T>() подписывает build-метод на изменения в ProductProvider.
    // При вызове notifyListeners() в провайдере этот виджет перестроится.
    final provider = context.watch<ProductProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text('Каталог товаров (${provider.products.length})'),
        centerTitle: true,
      ),
      // Если идёт самая первая загрузка — показываем спиннер по центру
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          // RefreshIndicator позволяет обновлять список свайпом сверху вниз
          : RefreshIndicator(
              onRefresh: () => provider.fetchInitialProducts(),
              child: ListView.builder(
                controller: _scrollController,
                // AlwaysScrollableScrollPhysics гарантирует работу свайпа (pull-to-refresh)
                // даже если элементов мало и список не заполняет экран целиком
                physics: const AlwaysScrollableScrollPhysics(),
                // +1 элемент в конце выделен под индикатор загрузки или сообщение об окончании
                itemCount: provider.products.length + 1,
                itemBuilder: (context, index) {
                  // ПРОВЕРКА: Если текущий индекс равен длине списка — это футер (хвост списка)
                  if (index == provider.products.length) {
                    if (provider.hasMore) {
                      // Если есть ещё данные — показываем индикатор загрузки следующей страницы
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20.0),
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      );
                    } else {
                      // Если данные закончились — показываем финальный текст
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24.0),
                        child: Center(
                          child: Text(
                            'Больше товаров нет 🎉',
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      );
                    }
                  }

                  // Иначе это обычный элемент списка: достаём товар по индексу
                  final product = provider.products[index];

                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    elevation: 1.5,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      // Превью изображения товара из сети
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          product.thumbnail,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            width: 56,
                            height: 56,
                            color: Colors.grey[200],
                            child: const Icon(Icons.image_not_supported, color: Colors.grey),
                          ),
                        ),
                      ),
                      title: Text(
                        product.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '\$${product.price}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
