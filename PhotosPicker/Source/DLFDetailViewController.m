//
//  DetailViewController.m
//  PhotosPicker
//
//  Created by  on 11/26/14.
//  Copyright (c) 2014 Delightful. All rights reserved.
//

#import "DLFDetailViewController.h"
#import "DLFPhotoCell.h"
#import "DLFAssetsLayout.h"
#import "DLFPhotosLibrary.h"
#import "DLFConstants.h"

typedef NS_ENUM(NSInteger, TouchPointInCell) {
    TouchPointInCellTopLeft,
    TouchPointInCellTopRight,
    TouchPointInCellBottomLeft,
    TouchPointInCellBottomRight
};

@import Photos;

@implementation NSIndexSet (Convenience)
- (NSArray *)aapl_indexPathsFromIndexesWithSection:(NSUInteger)section {
    NSMutableArray *indexPaths = [NSMutableArray arrayWithCapacity:self.count];
    [self enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:idx inSection:section]];
    }];
    return indexPaths;
}
@end


@implementation UICollectionView (Convenience)
- (NSArray *)aapl_indexPathsForElementsInRect:(CGRect)rect {
    NSArray *allLayoutAttributes = [self.collectionViewLayout layoutAttributesForElementsInRect:rect];
    if (allLayoutAttributes.count == 0) { return nil; }
    NSMutableArray *indexPaths = [NSMutableArray arrayWithCapacity:allLayoutAttributes.count];
    for (UICollectionViewLayoutAttributes *layoutAttributes in allLayoutAttributes) {
        NSIndexPath *indexPath = layoutAttributes.indexPath;
        [indexPaths addObject:indexPath];
    }
    return indexPaths;
}
@end

CGSize cellSize(UICollectionView *collectionView) {
    int numberOfColumns = 3;
    
    // this is to fix jerky scrolling in iPhone 6 plus
    if ([[UIScreen mainScreen] scale] > 2) {
        numberOfColumns = 4;
    }
    // end of fix
    
    CGFloat collectionViewWidth = collectionView.frame.size.width;
    CGFloat spacing = [(id)collectionView.delegate collectionView:collectionView layout:collectionView.collectionViewLayout minimumInteritemSpacingForSectionAtIndex:0];
    CGFloat width = floorf((collectionViewWidth-spacing*(numberOfColumns-1))/(float)numberOfColumns);
    return CGSizeMake(width, width);
}

TouchPointInCell positionInCell(UICollectionViewCell *cell, CGPoint touchPoint) {
    if (touchPoint.x < cell.frame.size.width/2 && touchPoint.y < cell.frame.size.height/2) {
        return TouchPointInCellTopLeft;
    } else if (touchPoint.x > cell.frame.size.width/2 && touchPoint.y > cell.frame.size.height/2) {
        return TouchPointInCellBottomRight;
    } else if (touchPoint.x < cell.frame.size.width/2 && touchPoint.y > cell.frame.size.height/2) {
        return TouchPointInCellBottomLeft;
    }
    return TouchPointInCellTopRight;
}

@interface DLFDetailViewController () <PHPhotoLibraryChangeObserver, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>

@property (strong) PHCachingImageManager *imageManager;
@property CGRect previousPreheatRect;
@property (nonatomic, strong, readonly) UIPinchGestureRecognizer *pinchGesture;
@property (nonatomic, strong, readonly) UILongPressGestureRecognizer *longGesture;
@property (nonatomic, strong, readonly) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong, readonly) UITapGestureRecognizer *tapGesture;
@property (nonatomic, assign) CGPoint initialLongGesturePoint;
@property (nonatomic, assign) CGPoint initialLongGestureCellCenter;
@property (nonatomic, strong) NSIndexPath *currentPannedIndexPath;
@property (nonatomic, strong) UIBarButtonItem *nextButton;

@end

@implementation DLFDetailViewController

static NSString * const CellReuseIdentifier = @"photoCell";
static CGSize AssetGridThumbnailSize;

- (void)awakeFromNib
{
    self.imageManager = [[PHCachingImageManager alloc] init];
    [self resetCachedAssets];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(photoLibraryDidChangeNotification:) name:DLFPhotosLibraryDidChangeNotification object:nil];
}

- (void)viewDidLoad {
    if (!self.assetsFetchResults) {
        self.title = NSLocalizedString(@"All Photos", nil);
        
        PHFetchOptions *options = [[PHFetchOptions alloc] init];
        options.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
        options.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d", PHAssetMediaTypeImage];
        self.assetsFetchResults = [PHAsset fetchAssetsWithOptions:options];
        
        [self.collectionView reloadData];
    }
    
    self.selectionManager = [DLFPhotosSelectionManager sharedManager];
    
    _pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinchGesture:)];
    [self.collectionView addGestureRecognizer:_pinchGesture];
    
    _longGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongGesture:)];
    [self.collectionView addGestureRecognizer:_longGesture];
    
    _tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTapGesture:)];
    [self.collectionView addGestureRecognizer:_tapGesture];
    
    _panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanGesture:)];
    [_panGesture setDelegate:self];
    [_panGesture requireGestureRecognizerToFail:_tapGesture];
    [self.collectionView addGestureRecognizer:_panGesture];
    
    [self.navigationController.interactivePopGestureRecognizer requireGestureRecognizerToFail:_panGesture];
    
    UIBarButtonItem *nextButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Next", nil) style:UIBarButtonItemStyleDone target:self action:@selector(didTapNextButton:)];
    UIButton *infoButton = [UIButton buttonWithType:UIButtonTypeInfoLight];
    [infoButton addTarget:self action:@selector(didTapHintButton:) forControlEvents:UIControlEventTouchUpInside];
    UIBarButtonItem *hintButton = [[UIBarButtonItem alloc] initWithCustomView:infoButton];
    UIBarButtonItem *spaceItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    spaceItem.width = 20;
    [self.navigationItem setRightBarButtonItems:@[nextButton, spaceItem, hintButton]];
    [nextButton setEnabled:NO];
    self.nextButton = nextButton;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(photoLibraryDidChangeNotification:) name:DLFPhotosLibraryDidChangeNotification object:nil];
    PHChange *change = [[DLFPhotosLibrary sharedLibrary] changeInstance];
    if (change) {
        [self photoLibraryDidChange:change];
    }
    
    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize size = cellSize(self.collectionView);
    AssetGridThumbnailSize = CGSizeMake(size.width * scale, size.height * scale);
    
    [self updateCachedAssets];
    [self.selectionManager addSelectionViewToView:self.view];
    [self.selectionManager.selectedPhotosView.clearSelectionButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [self.selectionManager.selectedPhotosView.clearSelectionButton addTarget:self action:@selector(didTapClearButton:) forControlEvents:UIControlEventTouchUpInside];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:DLFPhotosLibraryDidChangeNotification object:nil];
}

#pragma mark - Button

- (void)didTapClearButton:(id)sender {
    [self.selectionManager removeAllAssets];
    [self.collectionView reloadData];
    [self.nextButton setEnabled:NO];
}

- (void)didTapHintButton:(id)sender {
    NSString *message = NSLocalizedString(@"Slide to left or right to quickly select multiple photos. Give it a try!", nil);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Slide to Select", nil) message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"Close", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        
    }];
    [alert addAction:action];
    
    NSString *message2 = NSLocalizedString(@"Tap and hold a photo to zoom in", nil);
    UIAlertController *alert2 = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Long Tap Gesture", nil) message:message2 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *action2 = [UIAlertAction actionWithTitle:NSLocalizedString(@"Next", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self presentViewController:alert animated:YES completion:nil];
    }];
    [alert2 addAction:action2];
    [self presentViewController:alert2 animated:YES completion:nil];
}

- (void)didTapNextButton:(id)sender {
    if (self.delegate && [self.delegate respondsToSelector:@selector(detailViewController:didTapNextButton:photos:)]) {
        [self.delegate detailViewController:self didTapNextButton:sender photos:self.selectionManager.selectedAssets];
    }
}

#pragma mark - PHPhotoLibraryChangeObserver

- (void)photoLibraryDidChangeNotification:(NSNotification *)notification
{
    PHChange *changeInstance = notification.userInfo[DLFPhotosLibraryDidChangeNotificationChangeKey];
    
    [self photoLibraryDidChange:changeInstance];
}

- (void)photoLibraryDidChange:(PHChange *)changeInstance {
    // Call might come on any background queue. Re-dispatch to the main queue to handle it.
    dispatch_async(dispatch_get_main_queue(), ^{
        
        // check if there are changes to the assets (insertions, deletions, updates)
        PHFetchResultChangeDetails *collectionChanges = [changeInstance changeDetailsForFetchResult:self.assetsFetchResults];
        if (collectionChanges) {
            
            // get the new fetch result
            self.assetsFetchResults = [collectionChanges fetchResultAfterChanges];
            
            UICollectionView *collectionView = self.collectionView;
            
            if (![collectionChanges hasIncrementalChanges] || [collectionChanges hasMoves]) {
                // we need to reload all if the incremental diffs are not available
                [collectionView reloadData];
                
            } else {
                // if we have incremental diffs, tell the collection view to animate insertions and deletions
                [collectionView performBatchUpdates:^{
                    NSIndexSet *removedIndexes = [collectionChanges removedIndexes];
                    if ([removedIndexes count]) {
                        [collectionView deleteItemsAtIndexPaths:[removedIndexes aapl_indexPathsFromIndexesWithSection:0]];
                    }
                    NSIndexSet *insertedIndexes = [collectionChanges insertedIndexes];
                    if ([insertedIndexes count]) {
                        [collectionView insertItemsAtIndexPaths:[insertedIndexes aapl_indexPathsFromIndexesWithSection:0]];
                    }
                } completion:^(BOOL finished) {
                    NSIndexSet *changedIndexes = [collectionChanges changedIndexes];
                    if ([changedIndexes count]) {
                        [collectionView reloadItemsAtIndexPaths:[changedIndexes aapl_indexPathsFromIndexesWithSection:0]];
                    }
                }];
            }
            
            [self resetCachedAssets];
        }
    });
}

#pragma mark - Orientation

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self.collectionView.collectionViewLayout invalidateLayout];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        
    }];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return cellSize(collectionView);
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    return 1.f;
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    return 1;
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    NSInteger count = self.assetsFetchResults.count;
    return count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    DLFPhotoCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:CellReuseIdentifier forIndexPath:indexPath];
    
    // Increment the cell's tag
    NSInteger currentTag = cell.tag + 1;
    cell.tag = currentTag;
    
    PHAsset *asset = self.assetsFetchResults[indexPath.item];
    
    PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
    [options setVersion:PHImageRequestOptionsVersionCurrent];
    [options setResizeMode:PHImageRequestOptionsResizeModeFast];
    
    [self.imageManager requestImageForAsset:asset
                                 targetSize:AssetGridThumbnailSize
                                contentMode:PHImageContentModeAspectFill
                                    options:options
                              resultHandler:^(UIImage *result, NSDictionary *info) {
                                  if (cell.tag == currentTag) {
                                      cell.thumbnailImage = result;
                                  }
                              }];
    
    [cell setHighlighted:[self.selectionManager containsAsset:asset]];
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(detailViewController:configureCell:indexPath:asset:)]) {
        [self.delegate detailViewController:self configureCell:cell indexPath:indexPath asset:asset];
    }
    
    return cell;
}

- (BOOL)collectionView:(UICollectionView *)collectionView shouldHighlightItemAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    [self updateCachedAssets];
}

#pragma mark - Asset Caching

- (void)resetCachedAssets
{
    [self.imageManager stopCachingImagesForAllAssets];
    self.previousPreheatRect = CGRectZero;
}

- (void)updateCachedAssets
{
    BOOL isViewVisible = [self isViewLoaded] && [[self view] window] != nil;
    if (!isViewVisible) { return; }
    
    // The preheat window is twice the height of the visible rect
    CGRect preheatRect = self.collectionView.bounds;
    preheatRect = CGRectInset(preheatRect, 0.0f, -0.5f * CGRectGetHeight(preheatRect));
    
    // If scrolled by a "reasonable" amount...
    CGFloat delta = ABS(CGRectGetMidY(preheatRect) - CGRectGetMidY(self.previousPreheatRect));
    if (delta > CGRectGetHeight(self.collectionView.bounds) / 3.0f) {
        
        // Compute the assets to start caching and to stop caching.
        NSMutableArray *addedIndexPaths = [NSMutableArray array];
        NSMutableArray *removedIndexPaths = [NSMutableArray array];
        
        [self computeDifferenceBetweenRect:self.previousPreheatRect andRect:preheatRect removedHandler:^(CGRect removedRect) {
            NSArray *indexPaths = [self.collectionView aapl_indexPathsForElementsInRect:removedRect];
            [removedIndexPaths addObjectsFromArray:indexPaths];
        } addedHandler:^(CGRect addedRect) {
            NSArray *indexPaths = [self.collectionView aapl_indexPathsForElementsInRect:addedRect];
            [addedIndexPaths addObjectsFromArray:indexPaths];
        }];
        
        NSArray *assetsToStartCaching = [self assetsAtIndexPaths:addedIndexPaths];
        NSArray *assetsToStopCaching = [self assetsAtIndexPaths:removedIndexPaths];
        
        [self.imageManager startCachingImagesForAssets:assetsToStartCaching
                                            targetSize:AssetGridThumbnailSize
                                           contentMode:PHImageContentModeAspectFill
                                               options:nil];
        [self.imageManager stopCachingImagesForAssets:assetsToStopCaching
                                           targetSize:AssetGridThumbnailSize
                                          contentMode:PHImageContentModeAspectFill
                                              options:nil];
        
        self.previousPreheatRect = preheatRect;
    }
}

- (void)computeDifferenceBetweenRect:(CGRect)oldRect andRect:(CGRect)newRect removedHandler:(void (^)(CGRect removedRect))removedHandler addedHandler:(void (^)(CGRect addedRect))addedHandler
{
    if (CGRectIntersectsRect(newRect, oldRect)) {
        CGFloat oldMaxY = CGRectGetMaxY(oldRect);
        CGFloat oldMinY = CGRectGetMinY(oldRect);
        CGFloat newMaxY = CGRectGetMaxY(newRect);
        CGFloat newMinY = CGRectGetMinY(newRect);
        if (newMaxY > oldMaxY) {
            CGRect rectToAdd = CGRectMake(newRect.origin.x, oldMaxY, newRect.size.width, (newMaxY - oldMaxY));
            addedHandler(rectToAdd);
        }
        if (oldMinY > newMinY) {
            CGRect rectToAdd = CGRectMake(newRect.origin.x, newMinY, newRect.size.width, (oldMinY - newMinY));
            addedHandler(rectToAdd);
        }
        if (newMaxY < oldMaxY) {
            CGRect rectToRemove = CGRectMake(newRect.origin.x, newMaxY, newRect.size.width, (oldMaxY - newMaxY));
            removedHandler(rectToRemove);
        }
        if (oldMinY < newMinY) {
            CGRect rectToRemove = CGRectMake(newRect.origin.x, oldMinY, newRect.size.width, (newMinY - oldMinY));
            removedHandler(rectToRemove);
        }
    } else {
        addedHandler(newRect);
        removedHandler(oldRect);
    }
}

- (NSArray *)assetsAtIndexPaths:(NSArray *)indexPaths
{
    if (indexPaths.count == 0) { return nil; }
    
    NSMutableArray *assets = [NSMutableArray arrayWithCapacity:indexPaths.count];
    for (NSIndexPath *indexPath in indexPaths) {
        PHAsset *asset = self.assetsFetchResults[indexPath.item];
        [assets addObject:asset];
    }
    return assets;
}

#pragma mark - Gestures

- (void)handlePinchGesture:(UIPinchGestureRecognizer *)sender {
    DLFAssetsLayout *layout = (DLFAssetsLayout *)self.collectionView.collectionViewLayout;
    
    if (sender.state == UIGestureRecognizerStateBegan) {
        CGPoint initialPinchPoint = [sender locationInView:self.collectionView];
        NSIndexPath *pinchedCellPath = [self.collectionView indexPathForItemAtPoint:initialPinchPoint];
        layout.pinchedCellPath = pinchedCellPath;
        DLFPhotoCell *cell = (DLFPhotoCell *)[self.collectionView cellForItemAtIndexPath:pinchedCellPath];
        [cell setClipsToBounds:NO];
    } else if (sender.state == UIGestureRecognizerStateChanged) {
        layout.pinchedCellScale = sender.scale;
        layout.pinchedCellCenter = [sender locationInView:self.collectionView];
    } else if (sender.state == UIGestureRecognizerStateEnded) {
        DLFPhotoCell *cell = (DLFPhotoCell *)[self.collectionView cellForItemAtIndexPath:layout.pinchedCellPath];
        [cell setClipsToBounds:YES];
        layout.pinchedCellPath = nil;
        [self.collectionView performBatchUpdates:^{
            
        } completion:^(BOOL finished) {
            
        }];
    }
}

- (void)handleLongGesture:(UILongPressGestureRecognizer *)sender {
    DLFAssetsLayout *layout = (DLFAssetsLayout *)self.collectionView.collectionViewLayout;
    if (sender.state == UIGestureRecognizerStateBegan) {
        [UIView animateWithDuration:0.3 animations:^{
            CGPoint initialPinchPoint = [sender locationInView:self.collectionView];
            NSIndexPath *pinchedCellPath = [self.collectionView indexPathForItemAtPoint:initialPinchPoint];
            layout.pinchedCellPath = pinchedCellPath;
            layout.pinchedCellScale = 2.5;
            DLFPhotoCell *cell = (DLFPhotoCell *)[self.collectionView cellForItemAtIndexPath:pinchedCellPath];
            [cell setHighlighted:NO];
            CGPoint pointInCollectionView = [sender locationInView:self.collectionView];
            CGPoint pointInCell = [sender locationInView:cell];
            TouchPointInCell position = positionInCell(cell, pointInCell);
            switch (position) {
                case TouchPointInCellTopRight:
                    layout.pinchedCellCenter = CGPointMake(cell.frame.origin.x, cell.frame.origin.y + cell.frame.size.height);
                    break;
                case TouchPointInCellTopLeft:
                    layout.pinchedCellCenter = CGPointMake(cell.frame.origin.x + cell.frame.size.width, cell.frame.origin.y + cell.frame.size.height);
                    break;
                case TouchPointInCellBottomLeft:
                    layout.pinchedCellCenter = CGPointMake(cell.frame.origin.x + cell.frame.size.width, cell.frame.origin.y);
                    break;
                case TouchPointInCellBottomRight:
                    layout.pinchedCellCenter = cell.frame.origin;
                    break;
                default:
                    break;
            }
            
            [cell setClipsToBounds:NO];
            self.initialLongGesturePoint = pointInCollectionView;
            self.initialLongGestureCellCenter = layout.pinchedCellCenter;
        }];
    } else if (sender.state == UIGestureRecognizerStateChanged) {
        CGPoint pointInCollectionView = [sender locationInView:self.collectionView];
        CGFloat deltaX = pointInCollectionView.x - self.initialLongGesturePoint.x;
        CGFloat deltaY = pointInCollectionView.y - self.initialLongGesturePoint.y;
        layout.pinchedCellCenter = CGPointMake(self.initialLongGestureCellCenter.x+deltaX, self.initialLongGestureCellCenter.y+deltaY);
    } else if (sender.state == UIGestureRecognizerStateEnded) {
        DLFPhotoCell *cell = (DLFPhotoCell *)[self.collectionView cellForItemAtIndexPath:layout.pinchedCellPath];
        BOOL selected = NO;
        PHAsset *asset = self.assetsFetchResults[layout.pinchedCellPath.item];
        
        if ([self.selectionManager containsAsset:asset]) {
            selected = YES;
        }
        layout.pinchedCellPath = nil;
        [cell setClipsToBounds:YES];
        [cell setHighlighted:selected];
        [self.collectionView performBatchUpdates:^{
            
        } completion:^(BOOL finished) {
            
        }];
    }
}

- (void)handlePanGesture:(UIPanGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan) {
        CGPoint touchPoint = [sender locationInView:self.collectionView];
        NSIndexPath *pannedCellPath = [self.collectionView indexPathForItemAtPoint:touchPoint];
        self.currentPannedIndexPath = pannedCellPath;
        [self.collectionView setScrollEnabled:NO];
        [self panningDidTouchOnCellWithIndexPath:pannedCellPath];
    } else if (sender.state == UIGestureRecognizerStateChanged) {
        CGPoint touchPoint = [sender locationInView:self.collectionView];
        NSIndexPath *pannedCellPath = [self.collectionView indexPathForItemAtPoint:touchPoint];
        if (pannedCellPath != self.currentPannedIndexPath) {
            self.currentPannedIndexPath = pannedCellPath;
            [self panningDidTouchOnCellWithIndexPath:pannedCellPath];
        }
    } else if (sender.state == UIGestureRecognizerStateEnded) {
        self.currentPannedIndexPath = nil;
        [self.collectionView setScrollEnabled:YES];
    }
}

- (void)handleTapGesture:(UITapGestureRecognizer *)sender {
    CGPoint touchPoint = [sender locationInView:self.collectionView];
    NSIndexPath *tappedCellPath = [self.collectionView indexPathForItemAtPoint:touchPoint];
    [self toggleSelectedIndexPath:tappedCellPath];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ([gestureRecognizer isEqual:self.panGesture]){
        if ([otherGestureRecognizer isEqual:self.collectionView.panGestureRecognizer] || [otherGestureRecognizer isEqual:self.navigationController.interactivePopGestureRecognizer]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([gestureRecognizer isEqual:self.panGesture]) {
        CGPoint translation = [self.panGesture velocityInView:self.collectionView];
        return fabs(translation.y) <= AssetGridThumbnailSize.height/3 && fabs(translation.x)  >= 10;
    }
    return YES;
}

- (void)panningDidTouchOnCellWithIndexPath:(NSIndexPath *)indexPath {
    [self toggleSelectedIndexPath:indexPath];
}

- (void)toggleSelectedIndexPath:(NSIndexPath *)indexPath {
    BOOL selected = NO;
    PHAsset *asset = self.assetsFetchResults[indexPath.item];
    
    if ([self.selectionManager containsAsset:asset]) {
        if (indexPath) {
            [self.selectionManager removeAsset:asset];
        }
    } else {
        if (indexPath) {
            [self.selectionManager addSelectedAsset:asset];
            selected = YES;
        }
    }
    DLFPhotoCell *cell = (DLFPhotoCell *)[self.collectionView cellForItemAtIndexPath:indexPath];
    if (cell) {
        [cell setHighlighted:selected];
    }
    
    if (indexPath) {
        if (selected) {
            self.collectionView.contentInset = ({
                UIEdgeInsets inset = self.collectionView.contentInset;
                inset.bottom = self.selectionManager.selectedPhotosView.frame.size.height;
                inset;
            });
        } else {
            self.collectionView.contentInset = ({
                UIEdgeInsets inset = self.collectionView.contentInset;
                inset.bottom = 0;
                inset;
            });
        }
    }
    
    [self.nextButton setEnabled:(self.selectionManager.count==0)?NO:YES];
    [self.navigationController.interactivePopGestureRecognizer setEnabled:(self.selectionManager.count==0)?YES:NO];
}

@end
