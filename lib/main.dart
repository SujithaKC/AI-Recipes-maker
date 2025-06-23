
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const RecipeMakerApp());
}

class RecipeMakerApp extends StatelessWidget {
  const RecipeMakerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Recipe Maker',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        cardTheme: const CardTheme(
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
        ),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const RecipeMakerScreen(),
    );
  }
}

class RecipeMakerScreen extends StatefulWidget {
  const RecipeMakerScreen({super.key});

  @override
  _RecipeMakerScreenState createState() => _RecipeMakerScreenState();
}

class _RecipeMakerScreenState extends State<RecipeMakerScreen> {
  final TextEditingController _searchController = TextEditingController();
  final List<String> _ingredients = [];
  List<dynamic> _recipes = [];
  List<String> _wishlist = [];
  bool _isLoading = false;
  String _searchMode = 'name'; // 'ingredient' or 'name'

  @override
  void initState() {
    super.initState();
    _loadWishlist();
  }

  // Load wishlist from shared_preferences
  Future<void> _loadWishlist() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _wishlist = prefs.getStringList('wishlist') ?? [];
    });
  }

  // Save or remove recipe from wishlist
  Future<void> _toggleWishlist(String mealId, String mealName, Map<String, dynamic> recipe) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_wishlist.contains(mealId)) {
        _wishlist.remove(mealId);
        prefs.remove('recipe_$mealId');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$mealName removed from wishlist')),
        );
      } else {
        _wishlist.add(mealId);
        final recipeJson = jsonEncode(recipe);
        prefs.setString('recipe_$mealId', recipeJson);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$mealName added to wishlist')),
        );
      }
    });
    await prefs.setStringList('wishlist', _wishlist);
  }

  // Clean Markdown and invalid characters from API response
  String _cleanResponse(String rawResponse) {
    // Remove Markdown code fences (```json, ```)
    String cleaned = rawResponse.replaceAll(RegExp(r'^```json\s*', multiLine: true), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s*```$', multiLine: true), '');
    // Remove any other backticks
    cleaned = cleaned.replaceAll('`', '');
    // Trim whitespace
    cleaned = cleaned.trim();
    return cleaned;
  }

  // Fetch recipes from Gemini API
  Future<void> generateRecipes(String query, {bool isIngredient = false}) async {
    setState(() {
      _isLoading = true;
      _recipes = [];
    });

    String prompt;
    if (isIngredient) {
      prompt =
          "Generate a list of recipes that can be made using the following ingredients: ${_ingredients.join(', ')}. For each recipe, provide the name, category (e.g., Main Course, Dessert), cuisine (e.g., Italian, Indian), ingredients with measurements, and detailed instructions. Format the response as a JSON array of objects, each containing 'strMeal', 'strCategory', 'strArea', 'strInstructions', and 'strIngredients' (an array of objects with 'name' and 'measure').";
    } else {
      prompt =
          "Generate a recipe for a dish named '$query'. Provide the recipe name, category (e.g., Main Course, Dessert), cuisine (e.g., Italian, Indian), ingredients with measurements, and detailed instructions. Format the response as a JSON object with 'strMeal', 'strCategory', 'strArea', 'strInstructions', and 'strIngredients' (an array of objects with 'name' and 'measure').";
    }

    try {
      final response = await _callGeminiAPI(prompt);
      print('Gemini API Response: Status ${response.statusCode}, Body: ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Extract the text content and clean it
        final rawText = data['candidates']?[0]['content']?['parts']?[0]['text'] ?? '';
        if (rawText.isEmpty) {
          throw Exception('Empty or invalid response text');
        }
        final cleanedText = _cleanResponse(rawText);
        print('Cleaned Response: $cleanedText');
        // Parse the cleaned JSON
        final recipes = isIngredient ? jsonDecode(cleanedText) : [jsonDecode(cleanedText)];
        setState(() {
          _recipes = recipes.map((recipe) => _normalizeRecipe(recipe)).toList();
        });
        if (_recipes.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No recipes generated for this $_searchMode.')),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: Failed to generate recipes (Status: ${response.statusCode}, Body: ${response.body}).')),
        );
      }
    } catch (e) {
      print('Gemini API Error: $e, StackTrace: ${StackTrace.current}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: Failed to connect or parse Gemini API: $e')),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Call Gemini API
  Future<http.Response> _callGeminiAPI(String prompt) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('Gemini API key not found in .env file');
    }
    final url = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey';
    final headers = {'Content-Type': 'application/json'};
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ]
    });

    return await http.post(Uri.parse(url), headers: headers, body: body);
  }

  // Normalize Gemini API response to match app's expected format
  Map<String, dynamic> _normalizeRecipe(Map<String, dynamic> recipe) {
    return {
      'idMeal': recipe['idMeal'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      'strMeal': recipe['strMeal'] ?? 'Unknown',
      'strCategory': recipe['strCategory'] ?? 'Unknown',
      'strArea': recipe['strArea'] ?? 'Unknown',
      'strInstructions': recipe['strInstructions'] ?? 'No instructions.',
      for (int i = 0; i < (recipe['strIngredients']?.length ?? 0); i++)
        'strIngredient${i + 1}': recipe['strIngredients'][i]['name'] ?? '',
      for (int i = 0; i < (recipe['strIngredients']?.length ?? 0); i++)
        'strMeasure${i + 1}': recipe['strIngredients'][i]['measure'] ?? '',
    };
  }

  void _addIngredient() {
    final ingredient = _searchController.text.trim();
    if (ingredient.isNotEmpty && !_ingredients.contains(ingredient)) {
      setState(() {
        _ingredients.add(ingredient);
      });
      _searchController.clear();
    }
  }

  void _removeIngredient(String ingredient) {
    setState(() {
      _ingredients.remove(ingredient);
    });
  }

  void _onGenerateRecipes() {
    if (_searchMode == 'ingredient' && _ingredients.isNotEmpty) {
      setState(() {
        _isLoading = true;
        _recipes = [];
      });
      generateRecipes(_ingredients[0], isIngredient: true).then((_) {
        setState(() {
          _isLoading = false;
        });
      });
    } else if (_searchMode == 'name' && _searchController.text.trim().isNotEmpty) {
      setState(() {
        _isLoading = true;
        _recipes = [];
      });
      generateRecipes(_searchController.text.trim()).then((_) {
        setState(() {
          _isLoading = false;
        });
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _searchMode == 'ingredient'
                ? 'Please add at least one ingredient.'
                : 'Please enter a dish name.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Recipe Maker'),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.favorite),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => WishlistScreen(wishlist: _wishlist)),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Search Recipes',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'name',
                        label: Text('Dish Name'),
                        icon: Icon(Icons.search),
                      ),
                      ButtonSegment(
                        value: 'ingredient',
                        label: Text('Ingredients'),
                        icon: Icon(Icons.kitchen),
                      ),
                    ],
                    selected: {_searchMode},
                    onSelectionChanged: (newSelection) {
                      setState(() {
                        _searchMode = newSelection.first;
                        _ingredients.clear();
                        _searchController.clear();
                        _recipes = [];
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_searchMode == 'ingredient') ...[
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  hintText: 'e.g., chicken, tomato',
                  suffixIcon: IconButton(
                    onPressed: _addIngredient,
                    icon: const Icon(Icons.add_circle, color: Colors.green),
                  ),
                ),
                onSubmitted: (_) => _addIngredient(),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8.0,
                runSpacing: 4.0,
                children: _ingredients.map((ingredient) {
                  return Chip(
                    label: Text(ingredient),
                    backgroundColor: Colors.green[50],
                    onDeleted: () => _removeIngredient(ingredient),
                    deleteIcon: const Icon(Icons.close, size: 18),
                  );
                }).toList(),
              ),
            ] else ...[
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  hintText: 'e.g., Chicken Curry',
                  prefixIcon: const Icon(Icons.search),
                ),
                onSubmitted: (_) => _onGenerateRecipes(),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _isLoading ? null : _onGenerateRecipes,
              child: _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : Text(_searchMode == 'ingredient' ? 'Find Recipes' : 'Search Recipes'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Recipes',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _recipes.isEmpty
                      ? const Center(child: Text('No recipes found. Try a different search.'))
                      : ListView.builder(
                          itemCount: _recipes.length,
                          itemBuilder: (context, index) {
                            final recipe = _recipes[index];
                            final details = recipe;
                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                              child: ListTile(
                                contentPadding: const EdgeInsets.all(8),
                                title: Text(
                                  details['strMeal'] ?? 'Unknown',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                subtitle: Text(
                                  '${details['strCategory'] ?? 'Unknown'} • ${details['strArea'] ?? 'Unknown'}',
                                  style: TextStyle(color: Colors.grey[600], fontSize: 14),
                                ),
                                trailing: IconButton(
                                  icon: Icon(
                                    _wishlist.contains(recipe['idMeal'])
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: _wishlist.contains(recipe['idMeal']) ? Colors.red : Colors.grey,
                                  ),
                                  onPressed: () => _toggleWishlist(recipe['idMeal'], details['strMeal'], details),
                                ),
                                onTap: () {
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(details['strMeal'] ?? 'Recipe'),
                                      content: SingleChildScrollView(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Ingredients:',
                                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                            ),
                                            for (int i = 1; i <= 20; i++)
                                              if (details['strIngredient$i'] != null &&
                                                  details['strIngredient$i'].isNotEmpty)
                                                Text(
                                                  '- ${details['strMeasure$i']?.trim() ?? ''} ${details['strIngredient$i']}',
                                                  style: const TextStyle(fontSize: 14),
                                                ),
                                            const SizedBox(height: 12),
                                            const Text(
                                              'Instructions:',
                                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                            ),
                                            Text(
                                              details['strInstructions'] ?? 'No instructions.',
                                              style: const TextStyle(fontSize: 14),
                                            ),
                                          ],
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text('Close'),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}

class WishlistScreen extends StatefulWidget {
  final List<String> wishlist;

  const WishlistScreen({super.key, required this.wishlist});

  @override
  _WishlistScreenState createState() => _WishlistScreenState();
}

class _WishlistScreenState extends State<WishlistScreen> {
  List<Map<String, dynamic>> _wishlistRecipes = [];

  @override
  void initState() {
    super.initState();
    _loadWishlistRecipes();
  }

  Future<void> _loadWishlistRecipes() async {
    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> recipes = [];
    for (String mealId in widget.wishlist) {
      final recipeJson = prefs.getString('recipe_$mealId');
      if (recipeJson != null) {
        recipes.add(jsonDecode(recipeJson));
      }
    }
    setState(() {
      _wishlistRecipes = recipes;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wishlist'),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: _wishlistRecipes.isEmpty
            ? const Center(child: Text('No recipes in wishlist.'))
            : ListView.builder(
                itemCount: _wishlistRecipes.length,
                itemBuilder: (context, index) {
                  final details = _wishlistRecipes[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(8),
                      title: Text(
                        details['strMeal'] ?? 'Unknown',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      subtitle: Text(
                        '${details['strCategory'] ?? 'Unknown'} • ${details['strArea'] ?? 'Unknown'}',
                        style: TextStyle(color: Colors.grey[600], fontSize: 14),
                      ),
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(details['strMeal'] ?? 'Recipe'),
                            content: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Ingredients:',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  for (int i = 1; i <= 20; i++)
                                    if (details['strIngredient$i'] != null &&
                                        details['strIngredient$i'].isNotEmpty)
                                      Text(
                                        '- ${details['strMeasure$i']?.trim() ?? ''} ${details['strIngredient$i']}',
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Instructions:',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  Text(
                                    details['strInstructions'] ?? 'No instructions.',
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ],
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }
}