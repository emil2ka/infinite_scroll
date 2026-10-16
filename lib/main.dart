import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

void main() {
  runApp(const MyApp());
}

// ==========================================
// 1. МОДЕЛЬ ДАННЫХ
// ==========================================
class Product {
  final int id;
  final String title;
  final double price;
  final String thumbnail;

  Product({
    required this.id,
    required this.title,
    required this.price,
    required this.thumbnail,
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['id'],
      title: json['title'],
      price: (json['price'] as num).toDouble(),
      thumbnail: json['thumbnail'],
    );
  }
}

// ==========================================
// 2. ПРОВАЙДЕР ПАГИНАЦИИ (ProductProvider)
// ==========================================
class ProductProvider with ChangeNotifier {
  final List<Product> _products = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  int _skip = 0;
  final int _limit = 10;
  bool _hasMore = true;

  List<Product> get products => _products;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;

  /// Загружает одну страницу и возвращает список товаров (null при ошибке).
  Future<List<Product>?> _fetchPage() async {
    try {
      final response = await http.get(Uri.parse(
          'https://dummyjson.com/products?limit=$_limit&skip=$_skip'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return (data['products'] as List)
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('Ошибка сети: $e');
    }
    return null;
  }

  // Первичная загрузка (или Pull-to-Refresh)
  Future<void> fetchInitialProducts() async {
    _isLoading = true;
    _skip = 0;
    _hasMore = true;
    _products.clear();
    notifyListeners();

    final page = await _fetchPage();
    if (page != null) {
      _products.addAll(page);
      _skip += _limit;
      if (page.length < _limit) _hasMore = false;
    }

    _isLoading = false;
    notifyListeners();
  }

  // Подгрузка следующей порции (Infinite Scroll)
  Future<void> fetchMoreProducts() async {
    if (_isLoadingMore || _isLoading || !_hasMore) return;

    _isLoadingMore = true;
    notifyListeners();

    final page = await _fetchPage();
    if (page != null) {
      _products.addAll(page);
      _skip += _limit;
      if (page.length < _limit) _hasMore = false;
    }

    _isLoadingMore = false;
    notifyListeners();
  }
}

// ==========================================
// 3. ГЛАВНОЕ ПРИЛОЖЕНИЕ
// ==========================================
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ProductProvider()..fetchInitialProducts(),
      child: MaterialApp(
        title: 'Infinite Scroll Pagination',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          scaffoldBackgroundColor: Colors.white,
          colorScheme: const ColorScheme.light(
            primary: Colors.black,
            surface: Colors.white,
          ),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
        ),
        home: const ProductsScreen(),
      ),
    );
  }
}

// ==========================================
// 4. ЭКРАН СПИСКА С СКРОЛЛ-КОНТРОЛЛЕРОМ
// ==========================================
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 300) {
        context.read<ProductProvider>().fetchMoreProducts();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ProductProvider>();

    return Scaffold(
      body: provider.isLoading
          ? const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 1, color: Colors.black),
              ),
            )
          : RefreshIndicator(
              color: Colors.black,
              backgroundColor: Colors.white,
              onRefresh: () => provider.fetchInitialProducts(),
              child: CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverAppBar(
                    pinned: true,
                    centerTitle: true,
                    backgroundColor: Colors.white,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    toolbarHeight: 64,
                    title: const Text(
                      'КАТАЛОГ',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 6,
                        color: Colors.black,
                      ),
                    ),
                    bottom: PreferredSize(
                      preferredSize: const Size.fromHeight(1),
                      child: Container(height: 0.5, color: Colors.black26),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                      child: Text(
                        '${provider.products.length} ТОВАРОВ',
                        style: const TextStyle(
                          fontSize: 10,
                          letterSpacing: 2,
                          color: Colors.black54,
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 28,
                        crossAxisSpacing: 2,
                        childAspectRatio: 0.58,
                      ),
                      itemCount: provider.products.length,
                      itemBuilder: (context, index) =>
                          _ProductTile(product: provider.products[index]),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: provider.hasMore
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 1, color: Colors.black),
                              )
                            : const Text(
                                'КОНЕЦ КАТАЛОГА',
                                style: TextStyle(
                                  fontSize: 10,
                                  letterSpacing: 3,
                                  color: Colors.black45,
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final Product product;
  const _ProductTile({required this.product});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            color: const Color(0xFFF2F2F2),
            child: Image.network(
              product.thumbnail,
              fit: BoxFit.contain,
              frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 400),
                child: child,
              ),
              errorBuilder: (context, error, stack) => const Center(
                child: Icon(Icons.image_not_supported_outlined,
                    size: 20, color: Colors.black26),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
          child: Text(
            product.title.toUpperCase(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.2,
              height: 1.4,
              color: Colors.black,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: Text(
            '\$${product.price.toStringAsFixed(0)}',
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              color: Colors.black54,
            ),
          ),
        ),
      ],
    );
  }
}
