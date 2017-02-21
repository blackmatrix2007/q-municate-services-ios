//
//  QMUsersCache.m
//  QMUsersCache
//
//  Created by Andrey Moskvin on 10/23/15.
//  Copyright © 2015 Quickblox. All rights reserved.
//

#import "QMUsersCache.h"
#import "QMUsersModelIncludes.h"

#import "QMSLog.h"

@implementation QMUsersCache

static QMUsersCache *_usersCacheInstance = nil;

#pragma mark - Singleton

+ (QMUsersCache *)instance
{
    NSAssert(_usersCacheInstance, @"You must first perform @selector(setupDBWithStoreNamed:)");
    return _usersCacheInstance;
}

#pragma mark - Configure store

+ (void)setupDBWithStoreNamed:(NSString *)storeName applicationGroupIdentifier:(NSString *)appGroupIdentifier {
    
    NSManagedObjectModel *model =
    [NSManagedObjectModel QM_newModelNamed:@"QMUsersModel.momd"
                             inBundleNamed:@"QMUsersCacheModel.bundle"
                                 fromClass:[self class]];
    
    _usersCacheInstance = [[QMUsersCache alloc] initWithStoreNamed:storeName
                                                             model:model
                                                        queueLabel:"com.qmservices.QMUsersCacheQueue"
                                        applicationGroupIdentifier:appGroupIdentifier];
}

+ (void)setupDBWithStoreNamed:(NSString *)storeName
{
    return [self setupDBWithStoreNamed:storeName applicationGroupIdentifier:nil];
}

+ (void)cleanDBWithStoreName:(NSString *)name
{
    if (_usersCacheInstance) {
        _usersCacheInstance = nil;
    }
    [super cleanDBWithStoreName:name];
}

#pragma mark - Users

- (BFTask *)insertOrUpdateUser:(QBUUser *)user
{
    return [self insertOrUpdateUsers:@[user]];
}

- (BFTask *)insertOrUpdateUsers:(NSArray *)users
{
    __weak __typeof(self)weakSelf = self;
    
    BFTaskCompletionSource *source = [BFTaskCompletionSource taskCompletionSource];

    [self async:^(NSManagedObjectContext *backgroundContext) {
       
        NSMutableArray *toInsert = [NSMutableArray array];
        NSMutableArray *toUpdate = [NSMutableArray array];
        
        //To Insert / Update
        for (QBUUser *user in users) {
            
            
            CDUser *cachedUser = [CDUser QM_findFirstWithPredicate:IS(@"id", @(user.ID)) inContext:backgroundContext];
            
            if (cachedUser) {
                
                QBUUser *qbCachedUser = [cachedUser toQBUUser];
                
                if (![user.updatedAt isEqualToDate:qbCachedUser.updatedAt]) {
                    [toUpdate addObject:user];
                }
            }
            else {
                
                [toInsert addObject:user];
            }
        }
        
        if (toUpdate.count > 0) {
            
            [weakSelf updateUsers:toUpdate inContext:backgroundContext];
        }
        
        if (toInsert.count > 0) {
            
            [weakSelf insertUsers:toInsert inContext:backgroundContext];
        }
        
        QMSLog(@"[%@] Users to insert %tu, update %tu", NSStringFromClass([weakSelf class]), toInsert.count, toUpdate.count);
        
        if ([backgroundContext hasChanges]) {
            
            [backgroundContext QM_saveOnlySelfWithCompletion:^(BOOL success, NSError *error) {
                
                [source setResult:nil];
            }];
        }
        else {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                [source setResult:nil];
            });
        }
    }];
    
    return source.task;
}

- (BFTask *)deleteUser:(QBUUser *)user
{
    __weak __typeof(self)weakSelf = self;
    
    return [BFTask taskFromExecutor:[BFExecutor executorWithDispatchQueue:self.queue] withBlock:^id{
        __typeof(self) strongSelf = weakSelf;
        NSManagedObjectContext* context = [strongSelf backgroundSaveContext];
        
        CDUser *cachedUser = [CDUser QM_findFirstWithPredicate:IS(@"id", @(user.ID)) inContext:context];
        [cachedUser QM_deleteEntityInContext:context];
        
        [context QM_saveToPersistentStoreAndWait];
        
        return nil;
    }];
}

- (BFTask *)deleteAllUsers
{
    __weak __typeof(self)weakSelf = self;
    return [BFTask taskFromExecutor:[BFExecutor executorWithDispatchQueue:self.queue] withBlock:^id{
        __typeof(self) strongSelf = weakSelf;
        NSManagedObjectContext* context = [strongSelf backgroundSaveContext];
        
        [CDUser QM_truncateAllInContext:context];
        
        [context QM_saveToPersistentStoreAndWait];
        return nil;
    }];
}

- (BFTask *)userWithPredicate:(NSPredicate *) predicate
{
    BFTaskCompletionSource *source = [BFTaskCompletionSource taskCompletionSource];
    __weak __typeof(self)weakSelf = self;
    [BFTask taskFromExecutor:[BFExecutor executorWithDispatchQueue:self.queue] withBlock:^id{
        
        __typeof(self) strongSelf = weakSelf;
        NSManagedObjectContext* context = [strongSelf backgroundSaveContext];
        CDUser *user = [CDUser QM_findFirstWithPredicate:predicate inContext:context];
        QBUUser *result = [user toQBUUser];
        
        [source setResult:result];
        
        return nil;
    }];
    
    return source.task;
}

- (BFTask *)usersSortedBy:(NSString *)sortTerm ascending:(BOOL)ascending
{
    return [self usersWithPredicate:nil sortedBy:sortTerm ascending:ascending];
}

- (BFTask *)usersWithPredicate:(NSPredicate *)predicate sortedBy:(NSString *)sortTerm ascending:(BOOL)ascending
{
    BFTaskCompletionSource* source = [BFTaskCompletionSource taskCompletionSource];
    
    NSArray *users = [CDUser QM_findAllSortedBy:sortTerm ascending:ascending withPredicate:predicate inContext:self.context];
    NSArray *result = [self convertCDUsertsToQBUsers:users];
    
    [source setResult:result];
    
    return source.task;
}

#pragma mark - Private

- (void)insertUsers:(NSArray *)users inContext:(NSManagedObjectContext *)context {
    
    for (QBUUser *user in users) {
        
        CDUser *newUser = [CDUser QM_createEntityInContext:context];
        [newUser updateWithQBUser:user];
    }
}

- (void)updateUsers:(NSArray *)qbUsers inContext:(NSManagedObjectContext *)context {
    
    for (QBUUser *qbUser in qbUsers) {
        
        CDUser *userToUpdate = [CDUser QM_findFirstWithPredicate:IS(@"id", @(qbUser.ID)) inContext:context];
        [userToUpdate updateWithQBUser:qbUser];
    }
}

- (NSArray *)convertCDUsertsToQBUsers:(NSArray *)cdUsers {
    
    NSMutableArray *users =
    [NSMutableArray arrayWithCapacity:cdUsers.count];
    
    for (CDUser *user in cdUsers) {
        
        QBUUser *qbUser = [user toQBUUser];
        [users addObject:qbUser];
    }
    
    return users;
}

@end
