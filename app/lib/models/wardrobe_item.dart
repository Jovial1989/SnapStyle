/// Structured Digital Wardrobe item (backed by the `wardrobe_items` table).
/// `imagePath` points into the private `wardrobe` bucket (clean product shot);
/// resolve to a URL via LooktokApi.wardrobeImageUrl.
class WardrobeItem {
  const WardrobeItem(
      {required this.id, required this.category, required this.imagePath, required this.originalImagePath, required this.description});

  final String id;
  final String category; // top | bottom | outerwear | shoes | accessory | other
  final String imagePath; // ISOLATED garment (person/background removed)
  final String? originalImagePath; // the raw photo as shot (context), if kept
  final String description; // e.g. "white graphic t-shirt"

  factory WardrobeItem.fromRow(Map<String, dynamic> row) => WardrobeItem(
        id: (row['id'] ?? '').toString(),
        category: (row['category'] ?? 'other').toString(),
        imagePath: (row['image_path'] ?? '').toString(),
        originalImagePath: (row['original_image_path'] ?? '').toString().isEmpty ? null : row['original_image_path'].toString(),
        description: (row['label'] ?? '').toString(),
      );
}
