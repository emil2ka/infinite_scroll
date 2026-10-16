import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

void main() => runApp(const MyApp());

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

  Future<void> fetchInitialProducts() async {
    _isLoading = true;
    _skip = 0;
    _hasMore = true;
    _products.clear();
    notifyListeners();

    try {
      final url = Uri.parse('https://dummyjson.com/products?limit=$_limit&skip=$_skip');
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final List list = data['products'];
        _products.addAll(list.map((e) => Product.fromJson(e)).toList());
        _skip += _limit;
        if (list.length < _limit) _hasMore = false;
      }
    } catch (e) {
      debugPrint('Error: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> fetchMoreProducts() async {
    if (_isLoadingMore || !_hasMore) return;

    _isLoadingMore = true;
    notifyListeners();

    try {
      final url = Uri.parse('https://dummyjson.com/products?limit=$_limit&skip=$_skip');
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final List list = data['products'];
        _products.addAll(list.map((e) => Product.fromJson(e)).toList());
        _skip += _limit;
        if (list.length < _limit) _hasMore = false;
      }
    } catch (e) {
      debugPrint('Error: $e');
    }

    _isLoadingMore = false;
    notifyListeners();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ProductProvider()..fetchInitialProducts(),
      child: MaterialApp(
        title: 'Infinite Scroll',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
        home: const ProductsScreen(),
      ),
    );
  }
}

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
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
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
      appBar: AppBar(
        title: Text('Каталог товаров (${provider.products.length})'),
      ),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => provider.fetchInitialProducts(),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: provider.products.length + 1,
                itemBuilder: (context, index) {
                  if (index == provider.products.length) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24.0),
                      child: Center(
                        child: provider.hasMore
                            ? const CircularProgressIndicator()
                            : const Text('Больше товаров нет 🎉', style: TextStyle(color: Colors.grey)),
                      ),
                    );
                  }

                  final product = provider.products[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: ListTile(
                      leading: Image.network(
                        product.thumbnail,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                      ),
                      title: Text(product.title),
                      subtitle: Text('\$${product.price}'),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
