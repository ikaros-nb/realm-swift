////////////////////////////////////////////////////////////////////////////
//
// Copyright 2016 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMCollection_Private.hpp"

#import "RLMAccessor.hpp"
#import "RLMArray_Private.hpp"
#import "RLMDictionary_Private.hpp"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMObject_Private.hpp"
#import "RLMObservation.hpp"
#import "RLMProperty_Private.h"
#import "RLMSet_Private.hpp"
#import "RLMSwiftCollectionBase.h"

#import <realm/object-store/dictionary.hpp>
#import <realm/object-store/list.hpp>
#import <realm/object-store/results.hpp>
#import <realm/object-store/set.hpp>

static const int RLMEnumerationBufferSize = 16;

@implementation RLMFastEnumerator {
    // The buffer supplied by fast enumeration does not retain the objects given
    // to it, but because we create objects on-demand and don't want them
    // autoreleased (a table can have more rows than the device has memory for
    // accessor objects) we need a thing to retain them.
    id _strongBuffer[RLMEnumerationBufferSize];

    RLMRealm *_realm;
    RLMClassInfo *_info;
    RLMClassInfo *_parentInfo;
    RLMProperty *_property;

    // A pointer to either _snapshot or a Results from the source collection,
    // to avoid having to copy the Results when not in a write transaction
    realm::Results *_results;
    realm::Results _snapshot;

    // A strong reference to the collection being enumerated to ensure it stays
    // alive when we're holding a pointer to a member in it
    id _collection;
}

- (instancetype)initWithBackingCollection:(realm::object_store::Collection const&)backingCollection
                               collection:(id)collection
                                classInfo:(RLMClassInfo *)info
                               parentInfo:(RLMClassInfo *)parentInfo
                                 property:(RLMProperty *)property {
    self = [super init];
    if (self) {
        _info = info;
        _realm = _info->realm;
        _parentInfo = parentInfo;
        _property = property;

        if (_realm.inWriteTransaction) {
            _snapshot = backingCollection.as_results().snapshot();
        }
        else {
            _snapshot = backingCollection.as_results();
            _collection = collection;
            [_realm registerEnumerator:self];
        }
        _results = &_snapshot;
    }
    return self;
}

- (instancetype)initWithBackingDictionary:(realm::object_store::Dictionary const&)backingDictionary
                               dictionary:(RLMManagedDictionary *)dictionary
                                classInfo:(RLMClassInfo *)info
                               parentInfo:(RLMClassInfo *)parentInfo
                                 property:(RLMProperty *)property {
    self = [super init];
    if (self) {
        _info = info;
        _realm = _info->realm;
        _parentInfo = parentInfo;
        _property = property;

        if (_realm.inWriteTransaction) {
            _snapshot = backingDictionary.get_keys().snapshot();
        }
        else {
            _snapshot = backingDictionary.get_keys();
            _collection = dictionary;
            [_realm registerEnumerator:self];
        }
        _results = &_snapshot;
    }
    return self;
}

- (instancetype)initWithResults:(realm::Results&)results
                     collection:(id)collection
                      classInfo:(RLMClassInfo&)info {
    self = [super init];
    if (self) {
        _info = &info;
        _realm = _info->realm;
        if (_realm.inWriteTransaction) {
            _snapshot = results.snapshot();
            _results = &_snapshot;
        }
        else {
            _results = &results;
            _collection = collection;
            [_realm registerEnumerator:self];
        }
    }
    return self;
}

- (void)dealloc {
    if (_collection) {
        [_realm unregisterEnumerator:self];
    }
}

- (void)detach {
    _snapshot = _results->snapshot();
    _results = &_snapshot;
    _collection = nil;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                    count:(NSUInteger)len {
    [_realm verifyThread];
    if (!_results->is_valid()) {
        @throw RLMException(@"Collection is no longer valid");
    }
    // The fast enumeration buffer size is currently a hardcoded number in the
    // compiler so this can't actually happen, but just in case it changes in
    // the future...
    if (len > RLMEnumerationBufferSize) {
        len = RLMEnumerationBufferSize;
    }

    NSUInteger batchCount = 0, count = state->extra[1];

    @autoreleasepool {
        auto ctx = _parentInfo ? RLMAccessorContext(*_parentInfo, *_info, _property) :
        RLMAccessorContext(*_info);
        for (NSUInteger index = state->state; index < count && batchCount < len; ++index) {
            _strongBuffer[batchCount] = _results->get(ctx, index);
            batchCount++;
        }
    }

    for (NSUInteger i = batchCount; i < len; ++i) {
        _strongBuffer[i] = nil;
    }

    if (batchCount == 0) {
        // Release our data if we're done, as we're autoreleased and so may
        // stick around for a while
        if (_collection) {
            _collection = nil;
            [_realm unregisterEnumerator:self];
        }

        _snapshot = {};
    }

    state->itemsPtr = (__unsafe_unretained id *)(void *)_strongBuffer;
    state->state += batchCount;
    state->mutationsPtr = state->extra+1;

    return batchCount;
}
@end

NSUInteger RLMFastEnumerate(NSFastEnumerationState *state,
                            NSUInteger len,
                            id<RLMCollectionPrivate> collection) {
    __autoreleasing RLMFastEnumerator *enumerator;
    if (state->state == 0) {
        enumerator = collection.fastEnumerator;
        state->extra[0] = (long)enumerator;
        state->extra[1] = collection.count;
    }
    else {
        enumerator = (__bridge id)(void *)state->extra[0];
    }

    return [enumerator countByEnumeratingWithState:state count:len];
}

@interface RLMArrayHolder : NSObject
@end
@implementation RLMArrayHolder {
    std::unique_ptr<id[]> items;
}

NSUInteger RLMUnmanagedFastEnumerate(id collection, NSFastEnumerationState *state) {
    if (state->state != 0) {
        return 0;
    }

    // We need to enumerate a copy of the backing array so that it doesn't
    // reflect changes made during enumeration. This copy has to be autoreleased
    // (since there's nowhere for us to store a strong reference), and uses
    // RLMArrayHolder rather than an NSArray because NSArray doesn't guarantee
    // that it'll use a single contiguous block of memory, and if it doesn't
    // we'd need to forward multiple calls to this method to the same NSArray,
    // which would require holding a reference to it somewhere.
    __autoreleasing RLMArrayHolder *copy = [[RLMArrayHolder alloc] init];
    copy->items = std::make_unique<id[]>([collection count]);

    NSUInteger i = 0;
    for (id object in collection) {
        copy->items.get()[i++] = object;
    }

    state->itemsPtr = (__unsafe_unretained id *)(void *)copy->items.get();
    // needs to point to something valid, but the whole point of this is so
    // that it can't be changed
    state->mutationsPtr = state->extra;
    state->state = i;

    return i;
}
@end

template<typename Collection>
NSArray *RLMCollectionValueForKey(Collection& collection, NSString *key, RLMClassInfo& info) {
    size_t count = collection.size();
    if (count == 0) {
        return @[];
    }

    NSMutableArray *array = [NSMutableArray arrayWithCapacity:count];
    if ([key isEqualToString:@"self"]) {
        RLMAccessorContext context(info);
        for (size_t i = 0; i < count; ++i) {
            [array addObject:collection.get(context, i) ?: NSNull.null];
        }
        return array;
    }

    if (collection.get_type() != realm::PropertyType::Object) {
        RLMAccessorContext context(info);
        for (size_t i = 0; i < count; ++i) {
            [array addObject:[collection.get(context, i) valueForKey:key] ?: NSNull.null];
        }
        return array;
    }

    RLMObject *accessor = RLMCreateManagedAccessor(info.rlmObjectSchema.accessorClass, &info);
    auto prop = info.rlmObjectSchema[key];

    // Collection properties need to be handled specially since we need to create
    // a new collection each time
    if (info.rlmObjectSchema.isSwiftClass) {
        if (prop.collection && prop.swiftAccessor) {
            // Grab the actual class for the generic collection from an instance of it
            // so that we can make instances of the collection without creating a new
            // object accessor each time
            Class cls = [[prop.swiftAccessor get:prop on:accessor] class];
            for (size_t i = 0; i < count; ++i) {
                RLMSwiftCollectionBase *base = [[cls alloc] init];
                base._rlmCollection = [[[cls _backingCollectionType] alloc]
                                       initWithParent:collection.get(i) property:prop parentInfo:info];
                [array addObject:base];
            }
            return array;
        }
    }

    auto swiftAccessor = prop.swiftAccessor;
    for (size_t i = 0; i < count; i++) {
        accessor->_row = collection.get(i);
        if (swiftAccessor) {
            [swiftAccessor initialize:prop on:accessor];
        }
        [array addObject:[accessor valueForKey:key] ?: NSNull.null];
    }
    return array;
}

realm::ColKey columnForProperty(NSString *propertyName,
                                realm::object_store::Collection const& backingCollection,
                                RLMClassInfo *objectInfo,
                                RLMPropertyType propertyType,
                                RLMCollectionType collectionType) {
    if (backingCollection.get_type() == realm::PropertyType::Object) {
        return objectInfo->tableColumn(propertyName);
    }
    if (![propertyName isEqualToString:@"self"]) {
        NSString *collectionTypeName;
        switch (collectionType) {
            case RLMCollectionTypeArray:
                collectionTypeName = @"Arrays";
                break;
            case RLMCollectionTypeSet:
                collectionTypeName = @"Sets";
                break;
            case RLMCollectionTypeDictionary:
                collectionTypeName = @"Dictionaries";
                break;
        }
        @throw RLMException(@"%@ of '%@' can only be aggregated on \"self\"",
                            collectionTypeName, RLMTypeToString(propertyType));
    }
    return {};
}

template NSArray *RLMCollectionValueForKey(realm::Results&, NSString *, RLMClassInfo&);
template NSArray *RLMCollectionValueForKey(realm::List&, NSString *, RLMClassInfo&);
template NSArray *RLMCollectionValueForKey(realm::object_store::Set&, NSString *, RLMClassInfo&);

void RLMCollectionSetValueForKey(id<RLMCollectionPrivate> collection, NSString *key, id value) {
    realm::TableView tv = [collection tableView];
    if (tv.size() == 0) {
        return;
    }

    RLMClassInfo *info = collection.objectInfo;
    RLMObject *accessor = RLMCreateManagedAccessor(info->rlmObjectSchema.accessorClass, info);
    for (size_t i = 0; i < tv.size(); i++) {
        accessor->_row = tv[i];
        RLMInitializeSwiftAccessor(accessor, false);
        [accessor setValue:value forKey:key];
    }
}

void RLMAssignToCollection(id<RLMCollection> collection, id value) {
    [(id)collection replaceAllObjectsWithObjects:value];
}

NSString *RLMDescriptionWithMaxDepth(NSString *name,
                                     id<RLMCollection> collection,
                                     NSUInteger depth) {
    if (depth == 0) {
        return @"<Maximum depth exceeded>";
    }

    const NSUInteger maxObjects = 100;
    auto str = [NSMutableString stringWithFormat:@"%@<%@> <%p> (\n", name,
                [collection objectClassName] ?: RLMTypeToString([collection type]),
                (void *)collection];
    size_t index = 0, skipped = 0;
    for (id obj in collection) {
        NSString *sub;
        if ([obj respondsToSelector:@selector(descriptionWithMaxDepth:)]) {
            sub = [obj descriptionWithMaxDepth:depth - 1];
        }
        else {
            sub = [obj description];
        }

        // Indent child objects
        NSString *objDescription = [sub stringByReplacingOccurrencesOfString:@"\n"
                                                                  withString:@"\n\t"];
        [str appendFormat:@"\t[%zu] %@,\n", index++, objDescription];
        if (index >= maxObjects) {
            skipped = collection.count - maxObjects;
            break;
        }
    }

    // Remove last comma and newline characters
    if (collection.count > 0) {
        [str deleteCharactersInRange:NSMakeRange(str.length-2, 2)];
    }
    if (skipped) {
        [str appendFormat:@"\n\t... %zu objects skipped.", skipped];
    }
    [str appendFormat:@"\n)"];
    return str;
}

std::vector<std::pair<std::string, bool>> RLMSortDescriptorsToKeypathArray(NSArray<RLMSortDescriptor *> *properties) {
    std::vector<std::pair<std::string, bool>> keypaths;
    keypaths.reserve(properties.count);
    for (RLMSortDescriptor *desc in properties) {
        if ([desc.keyPath rangeOfString:@"@"].location != NSNotFound) {
            @throw RLMException(@"Cannot sort on key path '%@': KVC collection operators are not supported.", desc.keyPath);
        }
        keypaths.push_back({desc.keyPath.UTF8String, desc.ascending});
    }
    return keypaths;
}

@implementation RLMCollectionChange {
    realm::CollectionChangeSet _indices;
}

- (instancetype)initWithChanges:(realm::CollectionChangeSet)indices {
    self = [super init];
    if (self) {
        _indices = std::move(indices);
    }
    return self;
}

static NSArray *toArray(realm::IndexSet const& set) {
    NSMutableArray *ret = [NSMutableArray new];
    for (auto index : set.as_indexes()) {
        [ret addObject:@(index)];
    }
    return ret;
}

- (NSArray *)insertions {
    return toArray(_indices.insertions);
}

- (NSArray *)deletions {
    return toArray(_indices.deletions);
}

- (NSArray *)modifications {
    return toArray(_indices.modifications);
}

- (NSArray<NSIndexPath *> *)deletionsInSection:(NSUInteger)section {
    return RLMToIndexPathArray(_indices.deletions, section);
}

- (NSArray<NSIndexPath *> *)insertionsInSection:(NSUInteger)section {
    return RLMToIndexPathArray(_indices.insertions, section);
}

- (NSArray<NSIndexPath *> *)modificationsInSection:(NSUInteger)section {
    return RLMToIndexPathArray(_indices.modifications, section);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<RLMCollectionChange: %p> insertions: %@, deletions: %@, modifications: %@",
            (__bridge void *)self, self.insertions, self.deletions, self.modifications];
}

@end

namespace {
struct CollectionCallbackWrapper {
    void (^block)(id, id, NSError *);
    id collection;
    bool ignoreChangesInInitialNotification;

    void operator()(realm::CollectionChangeSet const& changes) {
        if (ignoreChangesInInitialNotification) {
            ignoreChangesInInitialNotification = false;
            block(collection, nil, nil);
        }
        else if (changes.empty()) {
            block(collection, nil, nil);
        }
        else if (!changes.collection_root_was_deleted || !changes.deletions.empty()) {
            block(collection, [[RLMCollectionChange alloc] initWithChanges:changes], nil);
        }
    }
};
} // anonymous namespace

@interface RLMCancellationToken : RLMNotificationToken
@end

RLM_HIDDEN
@implementation RLMCancellationToken {
    __unsafe_unretained RLMRealm *_realm;
    realm::NotificationToken _token;
    RLMUnfairMutex _mutex;
}

- (RLMRealm *)realm {
    std::lock_guard lock(_mutex);
    return _realm;
}

- (void)suppressNextNotification {
    std::lock_guard lock(_mutex);
    if (_realm) {
        _token.suppress_next();
    }
}

- (bool)invalidate {
    std::lock_guard lock(_mutex);
    if (_realm) {
        _token = {};
        _realm = nil;
        return true;
    }
    return false;
}

RLMNotificationToken *RLMAddNotificationBlock(id c, id block,
                                              NSArray<NSString *> *keyPaths,
                                              dispatch_queue_t queue) {
    id<RLMThreadConfined, RLMCollectionPrivate> collection = c;
    RLMRealm *realm = collection.realm;
    if (!realm) {
        @throw RLMException(@"Change notifications are only supported on managed collections.");
    }
    auto token = [[RLMCancellationToken alloc] init];
    token->_realm = realm;

    RLMClassInfo *info = collection.objectInfo;
    if (!queue) {
        [realm verifyNotificationsAreSupported:true];
        try {
            token->_token = [collection addNotificationCallback:block keyPaths:info->keyPathArrayFromStringArray(keyPaths)];
        }
        catch (const realm::Exception& e) {
            @throw RLMException(e);
        }
        return token;
    }

    RLMThreadSafeReference *tsr = [RLMThreadSafeReference referenceWithThreadConfined:collection];
    RLMRealmConfiguration *config = realm.configurationSharingSchema;
    dispatch_async(queue, ^{
        std::lock_guard lock(token->_mutex);
        if (!token->_realm) {
            return;
        }
        RLMRealm *realm = token->_realm = [RLMRealm realmWithConfiguration:config queue:queue error:nil];
        id collection = [realm resolveThreadSafeReference:tsr];
        token->_token = [collection addNotificationCallback:block keyPaths:info->keyPathArrayFromStringArray(keyPaths)];
    });
    return token;
}

realm::CollectionChangeCallback RLMWrapCollectionChangeCallback(void (^block)(id, id, NSError *),
                                                                id collection, bool skipFirst) {
    return CollectionCallbackWrapper{block, collection, skipFirst};
}
@end

NSArray *RLMToIndexPathArray(realm::IndexSet const& set, NSUInteger section) {
    NSMutableArray *ret = [NSMutableArray new];
    NSUInteger path[2] = {section, 0};
    for (auto index : set.as_indexes()) {
        path[1] = index;
        [ret addObject:[NSIndexPath indexPathWithIndexes:path length:2]];
    }
    return ret;
}
